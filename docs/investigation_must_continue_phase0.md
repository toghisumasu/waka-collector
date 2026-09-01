# 調査報告書：must_continue／must_switch 強化 Phase 0（計装追加＋原因調査）

- 依頼書：`docs/依頼書_must_continue強化_phase0.md`
- 参照：`docs/investigation_step3_mora_phase0.md`（100句本番走行結果、commit `76f3e93`）
- 対象データ：`observation_batch: sono76_step3fix_run100_20260830`（100句本番走行）
- 状態：**Step A 計装 diff を提示（実装前・人間承認待ち）／原因調査は既存ログで先行実施**

---

## 0. 前提の訂正（依頼書 §1 の一部）

依頼書は「`SeasonHintLogger` は `rengas_controller.rb` にしか include されておらず、
`observe_waka_extraction.rb` 経由では季ヒントのフラグ自体がログに残らない」としているが、
**現状のコードでは observe 経路にも計装がある**（部分的に）：

- `script/observe_waka_extraction.rb:290` が `controller.send(:log_season_hint, next_constraints, verse_no:)`
  を **各 verse 1回** 呼んでおり、`log/development.log` に `[SeasonHint]` 行が出ている。
- `SeasonHintLogger` のコメントも「RengasController と observe_production_hyakuin.rb の両方から呼ばれる」と明記。

したがって run100 の季ヒント推移は **既存ログから再構成できた**（→ §2）。ただし計装は不完全で、
Step A で埋めるべき穴が3つある（→ §3）。

---

## 1. 「句数：秋／春」違反の正体

`ShikimokuChecker#kukazo_violations`（`shikimoku_checker.rb:144-187`）の **検査②：春秋の最短規制**
（`type: :kukazo_under`）。

> 直前句の季が春／秋で、候補句が**別の季（または雑）へ転換する**とき、
> その春／秋セグメントの連続数が `min`（＝3）未満なら違反。

`compute_season_hint`（`:506-520`）：
- `current` … history 末尾の verse の季（＝直前に確定した句の季）
- `count`   … 末尾から連続して同じ季が続いている句数
- `must_continue` … `count < min`（春秋は min=3）→ **まだ続けねばならない**
- `must_switch`   … `count >= max`（春秋は max=5）→ **もう転じねばならない**

つまり「句数：秋 count=1 must_continue=true」は
**「直前句が秋と判定された。まだ秋1句目。次も秋を続けないと最短3句に達さず違反になる」** の意。

---

## 2. run100 の季ヒント推移（既存ログ再解析）

`log/development.log` の `[SeasonHint]` 行（run100 分）と、最終100句の本文から
`season_from_text` 相当で再判定した季セグメントを突合した。

### 2-1. ng を出した16 verse は **全て「季セグメント初句（count=1、must_continue=true）」**

| verse | 季ヒント | 事象 |
|---|---|---|
| 9, 13 | 秋 count=1 must_continue | retry 後に秋句へ収束 |
| 21 | 春 count=1 must_continue | **exhausted → forced_zatsu**（雑句で埋め） |
| 24, 30 | 春 count=1 must_continue | retry 後に春句へ収束 |
| 44 | 秋 count=1 must_continue | **exhausted → forced_zatsu** |
| 49 | 秋 count=1 must_continue | retry 後に収束 |
| 61 | 秋 count=1 must_continue | **exhausted → forced_zatsu** |
| 74 | 春 count=1 must_continue | **exhausted → forced_zatsu** |
| 75, 79, 83, 91, 97 | 秋 count=1 must_continue | 79・83 で多数 retry、83 は **forced_zatsu** |

`must_switch=true` は v28（春 count=5）と v59（冬 count=3）で発火。いずれも
その後正常に季を転じており、**must_switch 側の失敗は今回0件**。問題は must_continue に集中。

### 2-2. **retry ループの引き金は「幻の季セグメント」＝ season_from_text の巻き込み検出**

`season_from_text`（`rengas_controller.rb:210-214`）は `SEASON_WORDS` の**単純部分一致**。
秋語は `秋 月 紅葉 露 雁 鹿 萩 菊 竜田 嵐 時雨 霧 きり おみなえし ききょう`、
春語に `霞／かすみ` を含む。

run100 のペルソナ／gaze 語彙は **「露」「月」「かすみ」** を極めて高頻度で産む
（"露の重み" "露の光" "かすみ端に"…）。その結果：

| 直前句（パイプラインの意図は「雑」） | 混入語 | season_from_text 判定 | 次句への影響 |
|---|---|---|---|
| v60「草の葉先に露が震えし光る」 | 露 | **秋** | v61: 秋 count=1 must_continue → **exhausted → forced_zatsu** |
| v73「格子の外にかすみがそそり立ちし」 | かすみ | **春** | v74: 春 count=1 must_continue → **exhausted → forced_zatsu** |
| v82「遠き煙色朝溶け庭に露」 | 露 | **秋** | v83: 秋 count=1 must_continue → **exhausted → forced_zatsu** |
| v20「遠き浮かぶかすみ端に日影そっと」 | かすみ | **春** | v21: 春 count=1（※）→ **exhausted → forced_zatsu** |
| v8「指の隙間を過ぎる露の重み空」 | 露 | **秋** | v9: 秋 count=1 must_continue → retry×2 で収束 |

- **forced_zatsu 5句のうち少なくとも3句（v61・v74・v83）は、直前句への季語の
  偶発混入が作り出した「1句だけの幻の季セグメント」が原因。**
  パイプラインは自分がその季に入ったことを（seed 上）意図しておらず、
  次の2句を同季で続けられずに `kukazo_under` ループへ落ちる。
- 「露」「月」は連歌では明確な秋の季語であり、`season_from_text` の判定自体は
  式目上は正しい。問題は **生成側がその季語混入を検知も抑制もしていない** こと。

### 2-3. must_continue の指示は **LLM にほぼ渡っていない**

`:waka_extraction` は `RengaGenerator#generate_tsugeku:116` で `StepwiseWakaGenerator` へ
完全委譲し、`build_full_prompt` に到達しない。5d4e9a6（must_continue 時の
「まだ#{季}を続けるべき局面です。他の季節や無季（雑）に転じないこと。」）は
`RengaGenerator#directive_lines` にしか無く、**`StepwiseWakaGenerator#directive_lines`
（`stepwise_waka_generator.rb:291-308）は `[kigo_line, kinshi]` しか返さない**。

`StepwiseWakaGenerator` が季ヒントを使う箇所は1つだけ：
`season_label_for`（`:276-283`）
- `must_switch` なら `seed[:season] || "雑"`（seed 依存、nil なら雑）
- それ以外は `season_hint[:current]` → `season_label`

その `season_label` から `directive_lines` が出すのは：
- 秋語候補があれば `季語「X・Y」のいずれかを必ず詠み込むこと。`
- なければ `秋の情趣を詠むこと。`

**「雑や他季に転じるな」という禁止（5d4e9a6 の continue_line）は無い。**
かつ Step1 のプロンプトはペルソナ／gaze／自由詠みの枠組みが支配的で、
季語行はその他大勢の1行に埋もれている。結果、Step1 は季語を含まない
抽象的な感覚句を返し → `season_from_text` で雑 → `kukazo_under` で弾かれ → retry。

### 2-4. 「フラグは立っていたのに指示が渡っていなかった」— 依頼書 §4 の問いへの回答

**フラグ（`must_continue`）は正しく立っていた。** `[SeasonHint]` 行がそれを示す。
しかし：
1. その季セグメント自体が **season_from_text の巻き込みで偶発的に発生**していた
   ケースが forced_zatsu の主因（§2-2）。
2. フラグが正当なケースでも、**continue_line が `:waka_extraction` 経路に無く、
   LLM への指示が「季語を詠め」止まり**で弱い（§2-3）。

---

## 3. Step A：計装追加 diff（提示・実装前）

現状ログの穴：
- (a) `[SeasonHint]` は `development.log` にしか出ず、`stepwise_steps_*.jsonl` /
  `observation_*.jsonl` と **突合しづらい**（時刻頼み）。
- (b) `log_season_hint` は季が「雑」のとき early-return（`current` が nil）。
  **雑期間・雑への must_switch が記録されない**。
- (c) verse あたり1回・retry ループの**前**に1度だけ。各 Step1 draft が
  「どの季ヒント状態で・どんな season_label を渡されて」詠んだのかが
  構造化ログから追えない。

### 提案 diff（2ファイル、ロジック変更なし・ログのみ）

#### 変更1：`app/services/stepwise_waka_generator.rb`（Step1/Step2 の各行に季ヒントを載せる）

```diff
   def generate_free_verse(seed, persona)
     feedback = nil
     MAX_CONTENT_RETRIES.times do |retry_i|
       season_label = season_label_for(seed)
       # 詠み直しごとに距離帯を再抽選する（同じペルソナのまま別の情景へ移れる）。
       zone         = @gaze_mode == :literal ? nil : WakaPersona.resolve_zone(@constraints[:gaze_zone])
       prompt       = build_free_verse_prompt(seed, feedback, season_label, persona, zone)
-      log_extra    = { content_retry: retry_i + 1, season_label: season_label,
-                       gaze_mode: @gaze_mode, gaze_zone: zone && zone[:key],
-                       feedback_issue: feedback && feedback[:issue] }
+      sh           = @constraints[:season_hint] || {}
+      log_extra    = { content_retry: retry_i + 1, season_label: season_label,
+                       # 其の八十五 must_continue Phase0: 季ヒントを構造化ログへ載せる（計装のみ）
+                       season_current: sh[:current], season_count: sh[:count],
+                       must_switch: sh[:must_switch], must_continue: sh[:must_continue],
+                       seed_season: seed[:season],
+                       gaze_mode: @gaze_mode, gaze_zone: zone && zone[:key],
+                       feedback_issue: feedback && feedback[:issue] }
```

- `season_label` … パイプラインが目指した季（既存）
- `season_current` … ShikimokuChecker が直前句から見た季
- `season_count` / `must_continue` / `must_switch` … 季ヒントのフラグ
- `seed_season` … must_switch 時に season_label の元になる seed の季（nil 追跡用）

これで step1/step2 の各 jsonl 行が `batch/verse_no/attempt/draft_attempt/content_retry`
で突合でき、「どの draft が must_continue 局面だったか」「意図季と検出季の乖離」が追える。

#### 変更2：`script/observe_waka_extraction.rb`（観測 jsonl を自己完結させる）

```diff
     stage            = "next_constraints"
     next_constraints = checker.next_constraints(history)
     controller.send(:log_season_hint, next_constraints, verse_no: verse_no)
+    sh = next_constraints[:season_hint] || {}
+    log_line(log_file, {
+      verse_no: verse_no, attempt: 0, text: nil, mora_result: nil,
+      shikimoku_result: nil, violations: [], action: "season_hint",
+      season_current: sh[:current], season_count: sh[:count],
+      must_switch: sh[:must_switch], must_continue: sh[:must_continue]
+    })
```

`observation_*.jsonl` に `action: "season_hint"` 行が verse ごとに入り、
同ファイル内の attempt 行・違反行と直接突合できる（時刻突合が不要になる）。
※ (b) の「雑期間が出ない」は `log_season_hint` 側の早期returnが原因だが、
`SeasonHintLogger` は Web 経路と共用のため今回は触らず、この観測 jsonl 行
（早期returnしない）で代替する。

### 変更しないもの（依頼書 §3）

- `must_continue` / `must_switch` のロジック、`compute_season_hint`、`kukazo_violations`
- `season_from_text`、`SEASON_WORDS`
- `StepwiseWakaGenerator#directive_lines` / `season_label_for`（プロンプト内容）
- `RengasController`、`SeasonHintLogger`、`:direct` 経路

### ゲート影響の見込み

`log_extra` への鍵追加は `StepwiseStepLogger#append_step_record` の
`core.merge(extra.except(*core.keys))` を通るだけで、新鍵は core と衝突しない。
`verify_shikimoku.rb`（116 pass）・rspec（`stepwise_step_logger_spec` ほか）に影響なしの見込み。
**承認後、実装 → ゲート再確認 → 10句 smoke → 本節に実ログ添付。**

### 実装結果（人間承認済み）

- 承認：2026-08-31。上記2 diff をそのまま適用（`stepwise_waka_generator.rb` +6行 / `observe_waka_extraction.rb` +8行、ロジック変更なし）。
- ゲート：`verify_shikimoku.rb` **116 pass / 0 fail** 維持。
  rspec（`stepwise_step_logger_spec` + `stepwise_waka_generator_spec` + `verse_text_analysis_spec`）**62 examples 0 failures**。

---

## 4. 10句 smoke（計装確認）

- 走行：`bundle exec rails runner script/observe_waka_extraction.rb 10 mcflag_smoke`（2026-08-31、qwen3:14b）
- 発句：**けふこすはあすは雪とそふりなまし**（Waka#633）
- batch：`sono76_mcflag_smoke_20260830`（RUN_DATE は Time.zone.now=UTC のため 0830。
  stepwise ログは Time.now=JST で `log/stepwise_steps_20260831.jsonl`。突合は batch/verse_no で行う）
- 10/10 完走。ng率 23.1%（13 試行 / 3 ng）。forced_zatsu 0。

### 4-1. 計装は意図通り機能

**観測 jsonl（`action: "season_hint"` 行）** … 全 verse に出力。季が雑の局面も
`season_current: null` で記録される（`log_season_hint` の早期returnとは独立、穴(b)を解消）：

```
verse 1  season_current=冬 count=1 must_switch=false must_continue=false
verse 2  season_current=春 count=1 must_switch=false must_continue=true
verse 3  season_current=春 count=2 must_switch=false must_continue=true
verse 4  season_current=春 count=3 must_switch=false must_continue=false
verse 5  season_current=春 count=4 must_switch=false must_continue=false
verse 6  season_current=null count=0 must_switch=false must_continue=false
… verse 7-10 も season_current=null（雑期間）
```

**stepwise_steps jsonl（step1/step2 行）** … `season_current / season_count /
must_continue / must_switch / seed_season` が各 draft 行に載り、
`batch/verse_no/attempt/draft_attempt/content_retry` で観測 jsonl の retry 行と突合可能（穴(a)(c)を解消）。

### 4-2. must_continue 局面の retry を実地捕捉 —「季語の位置ずれ」が主因と判明

**verse 3（`句数:春` で1回 retry）の完全な追跡：**

| 段階 | 内容 | 季判定 |
|---|---|---|
| season_hint | 春 count=2 **must_continue=true** | 直前2句が春 |
| att1 Step1 draft3 出力 | 「うぐいすの声が草の間を滑る　空に浮かぶ雲の影も静かに」 | **春**（うぐいす）|
| att1 Step4 抽出（案2前ゲート, tanku） | → 「**空に浮かぶ雲の影も静か**」（後半14音を抽出） | **雑**（うぐいす脱落）|
| att1 ShikimokuChecker | `句数:春`（kukazo_under, 春 streak 2 < 3）→ retry | |
| att2 Step1 出力 | 「たんぽぽの綿が風に舞いながら　うぐいすの声が遠くに消えてゆく」 | 春 |
| att2 Step4 抽出 | → 「**うぐいすの声が遠くに消え**」（後半にうぐいすが在る）| **春** → ok |

**Step1 は季ヒント（season_label=春, seed_season=春）を受けて正しく春の句を詠んでいた。**
季語が脱落したのは **Step4 の位置固定抽出**（chōku は先頭17音、tanku は17音スキップ後の14音）で、
**季語が抽出窓の外にあると、抽出後の句が無季になる**。verse 3 は att1 で季語が前半に、
att2 でたまたま後半に来たため通った＝**位置の運**。

つまり must_continue 失敗は「フラグが立っていない」でも「指示が全く渡っていない」でもなく：

1. **（run100 の forced_zatsu 主因）** 直前句への季語偶発混入で「幻の季」が発生し、
   そもそも入る予定のなかった季を3句続けさせられる（§2-2）。
2. **（smoke で捕捉）** 正当な must_continue でも、Step1 は季を詠めているのに
   **Step4 の抽出で季語が切り落とされる**。5d4e9a6 の continue_line を移植しても、
   抽出段で季語が落ちれば同じ違反になる。

**verse 2 の「生成失敗」2件**は季と無関係（Step3⇄Step4 の音数逸脱・句切れ不自然の
deflock で全 draft×rewrite を消尽。[[step3_mora_phase0]] の二山・deflock 課題）。
ただし must_continue=true の局面で起きたため retry 数を押し上げている。

### 4-3. sono84 結論の再確認

`RengaGenerator#generate_tsugeku:116` の early-return は健在で、`:waka_extraction` は
`build_full_prompt`（＝5d4e9a6 の continue_line）に到達しない。
`StepwiseWakaGenerator` へ `constraints[:season_hint]` は渡っているが、使用箇所は
`season_label_for`（season_label の決定）のみで、`directive_lines` に continue 指示はない。
**sono84 時点の結論は正しい。** 唯一の補足は「season_hint が完全に無視されている」わけではなく
「season_label には効いているが、禁止・強制の言い回しが無い」という程度差。

---

## 5. 5d4e9a6 を `:waka_extraction` に適用する場合の実装方針案（実装はしない）

| 案 | 内容 | 長所 | 短所・リスク |
|---|---|---|---|
| **案 A**：continue_line 移植 | `StepwiseWakaGenerator#directive_lines` に 5d4e9a6 と同じ<br>「まだ#{季}を続けるべき局面です。他の季節や無季（雑）に転じないこと。」<br>を追加。`must_switch` 時は「今度は#{季}へ転じること」も。 | 最小差分。:direct と挙動を揃えられる。 | Step1 のプロンプトが既に長大。1行足しても<br>ペルソナ枠に埋もれる可能性（§2-3）。効果は限定的か。 |
| **案 B**：季語必須化を Step2 判定へ | must_continue/must_switch 時、`content_violation` に<br>「指定季の語が本文に無い」を違反として追加し Step1⇄Step2 で回収。 | 生成ループ内で早期に矯正。retry 総数を<br>Ollama 呼び出しの安いうちに消化。 | `stepwise_waka_generator.rb:191` のコメントが<br>「季語必須化は挙動変更のため見送り」と明記＝<br>過去に意図的に避けた線。要人間判断。 |
| **案 C**：seed 選択を季ヒントで絞る | must_continue/must_switch 時、`@pool.sample` を<br>`seed[:season] == 対象季` の seed に限定（無ければ従来）。 | 幻の季でなく「意図した季」に入りやすくなる。<br>Step1 の自由度を保ったまま季を誘導。 | pool に対象季の seed が乏しいと空振り。<br>`filter_pool` との二重フィルタで枯渇の懸念。 |
| **案 D**：幻の季セグメント自体を抑制 | Step2 or Step4 で、**パイプラインが雑を意図した draft に<br>秋語（露・月・霧…）が混入していたら弾く**（意図と検出の一致を要求）。 | forced_zatsu の主因（§2-2）を根絶。<br>「露」「月」の乱用（[[sono61_status]] の違反93%）にも効く。 | 「露」「月」を全面禁止すると叙景の幅が激減。<br>雑句限定でも Step1 の再詠み負荷増。 |
| **案 E**：`season_from_text` の判定を弱語で緩める | 「月」「露」等の単独混入では季と断定せず、<br>2語以上 or 強い季語のみ季とする。 | 幻の季の発生源を断つ。式目チェック全体が安定。 | **式目の解釈変更**＝連歌のルールに踏み込む。<br>依頼書 §3「ロジック変更禁止」に抵触。別トラック。 |
| **案 F**：抽出窓を季語に追従させる | must_continue/must_switch 時、Step4 の位置固定抽出で<br>季語が窓の外なら、季語を含む形態素境界へ窓を寄せる<br>（既存 `tolerance` 機構の季版）。 | §4-2 で捕捉した「季語の位置ずれ」を直接是正。<br>Step1 は既に季を詠めているので生成負荷ゼロ。 | `verse_text_analysis` の抽出ロジック変更＝<br>[[step3_mora_phase0]] 案1 と干渉。前回スコープの<br>Step4 に再び触れることになる。 |

### Phase 1 に向けた所感

- **単独では案A では足りない**。10句 smoke（§4-2）で、Step1 は season_label を受けて
  正しく春を詠んでいたのに Step4 抽出で季語が脱落して `句数:春` になった。
  continue_line を移植しても抽出段の脱落は直らない。
- run100 の実害（forced_zatsu 5句）の主因はさらに手前 —
  **「意図しない季に入れられていること」（§2-2、幻の季セグメント）**。
- 想定される Phase 1 の組み合わせ：
  1. **案C（seed 誘導）** … 幻の季でなく意図した季に入りやすくする。効果の土台。
  2. **案F（抽出窓の季追従）** … Step1 が詠んだ季語を抽出で落とさない。smoke で捕捉した経路の是正。
  3. **案A（明示指示）** … 上2つの補助。単独では弱いが低コスト。
- 案D・案E は「露・月」の扱い／式目解釈に踏み込むため、[[sono61_status]]（「夢」「月」違反93%）と
  合わせて別スコープ。案B は過去に意図的に見送った線（`stepwise_waka_generator.rb:191` コメント）。
- **seed_season 分布（案C の実現可能性）**：10句 smoke の step1 行では seed_season は
  当該季（春局面で seed_season=春）が取れていた。100句規模での pool 内訳は Phase 1 の
  設計時に別途集計する（`stepwise_steps` の `seed_season` フィールドで観測可能になった）。

---

## 6. Phase 1 実装結果（案C＋案F＋案A）

- 依頼書：`docs/依頼書_must_continue強化_phase1.md`
- 承認：2026-09-01、確率バイアス版の案Cを含む3案のdiffを人間承認（D-33-1）。
- 実装：`app/services/stepwise_waka_generator.rb` の1ファイルのみ（+89 / -4行）。
  `:direct`（`RengaGenerator`）・`RengasController`・`VerseTextAnalysis`・保護ファイルには不接触。
  `filter_pool` は `:direct` 共用のため触れず、`:waka_extraction` 経路の抽選点・抽出点でのみ効かせた。

### 6-1. 実装内容

| 案 | 追加 | 挙動 |
|---|---|---|
| **C** | `ZATSU_SEED_BIAS = 0.75` / `sample_seed`（`generate` の `@pool.sample` を置換） | 雑の局面（`season_hint[:current]` が nil）で、確率 0.75 で雑 seed（`season: nil`）へ偏重。残余 0.25 では全 pool から抽選し季の自然な開始も残す（絶対フィルタにしない）。`must_switch`/季継続局面は `filter_pool` と同義の防御的二重化。 |
| **F** | `shift_window_to_kigo`（`extract_and_validate` から呼ぶ） | `must_continue`/`must_switch` 局面かつ、既定の抽出窓に対象季の季語が無いが本文全体には在る場合、窓の開始形態素を 0..季語位置 で走査し、季語を含み・端が自然（`clean_phrase_edges?`）で・前句エコーでない候補のうち既定窓に最も近いものを返す。該当なしなら nil＝既定 seg 維持（構造的妥当性は退行しない）。 |
| **A** | `directive_lines` に continue_line / switch_line、`build_free_verse_prompt` へ配線 | `must_continue`（かつ季≠雑）で「まだ〇を続けるべき局面です。他の季節や無季（雑）に転じないこと。」、`must_switch` で「季を転じるべき局面です。前句の季を続けず、〇へ転じること。」を Step1 プロンプトへ追加。5d4e9a6（`:direct`）の移植。 |

### 6-2. ゲート・spec

- `bundle exec ruby script/verify_shikimoku.rb` … **116 pass / 0 fail** 維持。
- `stepwise_waka_generator_spec` + `verse_text_analysis_spec` + `stepwise_step_logger_spec` … **62 examples / 0 failures**。
- `:direct`・`RengasController`・既存テストに新規 failure なし。

### 6-3. 10句 smoke（`observe_waka_extraction.rb 10 mcflag_p1_smoke`、2026-09-01、qwen3:14b）

- 発句：**ひとりねのわひしきままにおきゐつつ**（Waka#1788）／batch `sono76_mcflag_p1_smoke_20260901`
- 10/10 完走。**ng率 9.1%（11 試行 / 1 ng）**。**forced_zatsu 0句**。違反種別内訳：0件。
  （Phase0 §4 の10句 smoke は ng率 23.1%・forced_zatsu 0。同一発句ではないため厳密比較は不可だが悪化はない）
- 唯一の ng は v9 の「生成失敗」（Step3⇄Step4 の deflock、`must_continue=false` 局面、季節と無関係。
  [[step3_mora_phase0]] の二山・deflock 課題で本 Phase のスコープ外）。

#### 経路1（幻の季セグメント）— 発生したが破綻せず吸収された

`action:"season_hint"` 行と最終本文の突合：

| verse | 本文 | season_from_text | 次 verse への季ヒント |
|---|---|---|---|
| v2 | 指先に宿る露の重み見上げれ | **秋**（露） | v3: 秋 count=1 **must_continue** |
| v3 | 耳に押し寄せて秋の夜 | 秋（秋） | v4: 秋 count=2 must_continue |
| v4 | 萩の香り漂う露に足 | 秋（萩・露） | v5: 秋 count=3 |
| v5 | 抜け指先触れる涼しさ | 雑 | v6: 雑（セグメント正常閉じ） |

- **案C は seed 経由の季語混入を抑制した**：雑局面の step1 draft 20件中 18件が雑 seed（`seed_season=nil`）、
  季 seed はわずか 2件。v2 の seed も「となりの方に」「うちさわかれて」等すべて非季。
- **しかし v2 の「露」はペルソナ／gaze 語彙由来**（"草の葉先に露が垂れかかる" "指先に宿る露の重みを"）で、
  案C の守備範囲外（Phase0 §2-2・案D/E スコープ）。幻の秋セグメントは発生した。
- **決定的な違いは、その幻セグメントが破綻しなかったこと**：v3・v4 の Step1 が案A（continue_line）を受けて
  強く秋へ寄り（"菊の影…" "枯葉の上で震えし露の音を…" "萩の香り漂う露に足を濡らし…"）、
  season_from_text が秋を検出し続け、**最短3句を違反ゼロ・forced_zatsu ゼロで満たして v5 で雑へ正常復帰**した。
  run100 では同型の幻セグメント（v61/v74/v83）がいずれも `kukazo_under` ループ → forced_zatsu を誘発していた。

#### 経路2（抽出窓での季語脱落）— 今回の smoke では案Fの発火は不要だった

- v3（tanku）：Step3 が末尾に「秋の夜」を付加したため既定窓（skip 17）に季語が入り、案F は早期 return。
- v4（chouku）：既定窓（skip 0）が先頭の「萩の香り漂う露に足」を捕捉、季語入りのため案F は早期 return。
- つまり10句 smoke では「位置の運」が良い方に転がり、案F が救済すべき局面が発生しなかった。
  **案F の実効性は別途、直接テストで確認**：
  ```
  free_text  = "萩の花咲く野の道を歩みつつ遠くの空に日が沈みゆく"（tanku 想定）
  既定窓(skip17,take14) → "遠くの空に日が沈みゆく"（無季）
  案F shift_window_to_kigo → "萩の花咲く野の道を歩み"（萩あり・端自然）
  非 must_* 局面では nil（no-op）
  ```
  → 既定窓が季語を落とす局面で、案F が季語入り・端の自然な窓へ正しくスライドすることを確認。

### 6-4. Step3 側への副作用

- 案F が抽出窓を動かした本番局面は smoke 中は0件（上記のとおり）。モーラ精度・`clean_phrase_edges?`・
  総モーラ許容（±2）への影響なし。
- 案F は候補が既存ガード（clean edges・前句エコー・総モーラ）を全通過した場合のみ seg を差し替え、
  非該当時は既定 seg を維持するため、構造的妥当性を退行させない設計。

### 6-5. 所感と次段

- 10句規模では ng率・forced_zatsu ともに良好。**案A が「幻セグメントを破綻させない」主効果**を担い、
  **案C が幻セグメントの発生頻度を下げ**、**案F は保険**として実装済み（今回は不発）。
- 経路1 の残存要因（ペルソナ／gaze 語彙の「露・月・かすみ」）は案D/E スコープで別途。
- `ZATSU_SEED_BIAS = 0.75` は連歌コーパスの雑連続長からの初期値。`seed_season` 計装で分布を観測し
  100句規模で調整余地を見る。
- **100句本番走行は次回の別依頼書として起票**（今回スコープは10句まで）。案F の実効性は100句規模で
  初めて本番局面に当たる見込み。

---

## 7. Phase 1 100句本番走行結果（`sono76_mcflag_p1_run100_20260901`）

- 依頼書：`docs/依頼書_phase1_run100_集計報告.md`
- 発句：**月かへて君をは見むといひしかと**（Waka#1846）
- ログ：`log/observation_sono76_mcflag_p1_run100_20260901.jsonl`／`log/observation_sono76_calls_...jsonl`／
  `log/stepwise_steps_20260902.jsonl`（`batch=sono76_mcflag_p1_run100_20260901` で突合）
- 100/100句完走。**ng率 11.5%（113試行 / 13ng）**。**forced_zatsu 0句**（モーラng許容0句）。

### 7-1. ng率・内訳の詳細

`action:"retry"` 13件を `violations` と `log/stepwise_steps_20260902.jsonl` の step2/step4 突合で分類：

| 違反種別 | 件数 | verse（attempt） |
|---|---|---|
| must_continue起因（句数:秋） | 5件 | v13（attempt1〜3）／v89（attempt1〜2） |
| 句去:七句去物 | 2件 | v55（attempt1）／v90（attempt1） |
| Step3 deflock（生成失敗＝5draft×5rewrite全滅） | 5件 | v21・v29・v39・v75（attempt2）・v99 |
| その他（Ollama接続タイムアウト180秒） | 1件 | v75（attempt1） |
| **合計** | **13件** | 総試行113回中 |

- 「句数:秋」5件は**全件が`season_count=1・must_continue=true`の季セグメント初句**（v13・v89とも該当）。
  Phase0 §2-1「ng を出した16 verse は全て季セグメント初句」の構造が100句規模でも再現している
  （発生頻度は5句/13件と大幅に縮小したが、発生パターンそのものは温存）。
- Step3 deflock 5件は、該当5verseとも**Step2（内容判定）は5draftすべて一発通過**（`content_violation`なし）で、
  失敗は完全にStep3⇄Step4（31音書き換え⇄機械抽出）の往復に限局していた（各draft25回のstep4呼び出し、
  5draft×5回＝125コールが全滅）。季ヒントとは無関係な純粋な[[step3_mora_phase0]]系の課題
  （v21のみ`must_switch=true`局面と時間的に重なるが、失敗機序はStep3のモーラ書き換えであり季検出とは無関係）。
- forced_zatsu 0句：script集計（`script/observe_waka_extraction.rb`本体の走行時カウント）どおり。
  モーラng許容による救済も0件で、100句すべてがShikimokuChecker通過済みの句として確定した。

### 7-2. 経路1（幻の季セグメント）の再発有無

`action:"season_hint"` 100行から季セグメントの開始／終了を再構成し、各開始点の**引き金語**（直前verseの本文中で
`SEASON_WORDS`に最初にマッチした語）を確認した。

| 季セグメント開始 | 引き金verse・語 | 種別 |
|---|---|---|
| v9（秋） | v8「…**露**が震えし…」 | 偶発（露） |
| v13（秋） | v12「**露**の滴る瓦に…」 | 偶発（露） |
| v16（冬） | v15「光りし**も**手のひらに…」 | **誤検出**（古典助詞「しも」を`SEASON_WORDS[:winter]`の「しも」＝霜に誤マッチ） |
| v17（春） | v16「遠き**かすみ**に霜の粉降る…」 | 語彙は正当だが同文に冬語「霜」も混在（spring優先の走査順で春判定） |
| v27／v31／v45（春） | v26／v30／v44「…**かすみ**わたる／ゆらめく／の色が…」 | 意図的な春描写（正当） |
| v53／v60／v79／v85／v89（秋） | 直前verse「**露**が震え／濡れてく／滴る音…」 | 偶発（露）×5 |

- **経路1は今回も頻発した**：季セグメント開始16件中7件が「露」の偶発混入、1件が「しも」の
  文字列誤マッチという新種の誤検出（[[sono85_must_continue_phase0]]で既知の露・月・かすみに加え、
  ひらがな部分一致の副作用として新規に確認）。
  「しも」誤検出はv16を誤って冬局面に倒したが、v16の実出力「遠きかすみに霜の粉降る手のひら」は
  結果的に本物の霜語彙を含んでおり実害は生じなかった（偶然の一致で破綻を免れたケース）。
- **forced_zatsu 0句へ改善した理由**：露などによる幻セグメントの発生自体は案Cで根絶されていない
  （sample_seedはseedの季選択だけを制御し、ペルソナ／gaze語彙由来の「露」混入は守備範囲外＝Phase0記載どおり）。
  改善の主因は、幻セグメントが立ったあとに**破綻せず吸収された**こと：v13・v89（露起因の季セグメント初句）は
  ともにretryが発生したが、v13はattempt4で・v89はattempt3で最終的に季継続を満たす句を生成でき、
  forced_zatsuへ転落しなかった。10句smokeで確認した「案Aのcontinue_lineが幻セグメントを破綻させずに
  吸収する」効果が100句規模でも機能したと判断できる。
- **ZATSU_SEED_BIASの妥当性**：雑局面（`season_current=None`）でのstep1呼び出し100件中、
  `seed_season=nil`（雑seed採用）は94件（94%）。名目値0.75からの単純予測より高いが、
  `@pool`自体の季なしseed比率が59.6%（3854件中2298件、`build_seed_pool`実測）であるため、
  期待値は `0.75×1.0 + 0.25×0.596 ≒ 89.9%` となり、実測94%はこの期待値から二項分布の1標準偏差
  （n=100で約3pt）圏内に収まる。**0.75は設計どおりに機能しており、値そのものを疑う根拠はない**
  （§3で禁止のため値変更はせず、次回以降の判断材料として記録のみ）。

### 7-3. 経路2（案Fの本番発火）の確認

`shift_window_to_kigo`はログに発火フラグを持たないため、`log/stepwise_steps_20260902.jsonl`の
`input_text`（Step3出力）を実際の`StepwiseWakaGenerator`private メソッドへ`send`で再投入し
（Ollama呼び出しなし、既存ロジックの再現のみ、app/配下は無改修）、`must_continue`/`must_switch`局面の
step4レコード180件を全件検証した。

- **候補を検出**：42件で非nilの`shifted`候補を検出（既定窓に季語が無いが本文全体には在る局面）。
- **実際に採用**：うち12件で最終`extracted`が`shifted`と一致＝案Fの候補がStep4の出力として採用された。
  残り30件は「候補は見つかったが総モーラ許容±2音を外れて棄却」（`extract_and_validate`の`over`判定は
  抽出窓と独立に本文全体の総モーラ数で行われるため、季語を窓に収められても長さ超過なら不採用になる設計）。
- **最終句への到達**：12件中10件（v3・v9・v13・v27・v41・v45・v53・v79・v85・v89）は、
  実際にconsole出力の最終確定句と完全一致した。**案Fが100句中10句（10%）の最終確定句を
  直接生成した**ことになる（残り2件＝v13 attempt2・v89 attempt1は、Step4通過後にShikimoku側の
  「句数:秋」で別途棄却され、後続attemptで再挑戦している）。
  例：v85「もみじの裂けた掌に月」＝既定窓「揺れ遠き空に風の声」（無季）→案Fが本文中の「もみじ」を
  含む窓へスライドして採用。v89（attempt3）「しぐれの音に揺れる紅葉」＝既定窓「枯れ枝がざわめく風が過ぎる」
  （無季）→「しぐれ」を含む窓へスライド。
- **副作用**：42件すべて`extract_mora_segment`の同一許容誤差（±1音）・`clean_phrase_edges?`ガードを
  経由しており、モーラ精度や句切れの自然さで既定窓抽出と異なる基準は適用されていない。
  10句smokeでは「不発」だった案Fが、100句規模で狙いどおり実戦発火し、しかも最終句の1割を
  実際に左右する主要経路になっていることを確認した。

### 7-4. レイテンシ・呼出量の詳細

| 指標 | Phase1前 run100（`step3fix_run100`） | Phase1 run100 |
|---|---|---|
| step3_mora_rewrite 呼出回数 | 1215回 | **639回（−47%）** |
| deflock率（rewrite_attempt5到達率） | 74% | **61.9%（104/168 draft列）** |

- 呼出回数の減少（1215→639）とdeflock率の低下（74%→61.9%）は連動しており、案C・案Fによる
  「季局面での手戻り」削減がStep3側の空転も間接的に減らしたと考えられる（案自体はStep3のロジックに
  一切触れていないため、上流のStep1〜Step2でのリトライ削減が波及した効果）。61.9%はなお過半数が
  deflockに達しており、[[step3_mora_phase0]]の構造課題（二山・deflock）は未解消のまま。
- v75のタイムアウト詳細：`log/observation_sono76_calls_...jsonl`を突合すると、attempt1の
  直前3回のstep3呼び出しは3.5〜6.1秒で正常応答し、直後（attempt2以降）も1.7〜4.5秒で安定している。
  180秒張り付きはこの1回のみの孤立事象であり、前後のレイテンシに劣化傾向は見られない。
  **Ollama側の一時的な詰まり（構造的な問題ではない）と判断**する。全体所要への影響も
  attempt2の生成失敗（117秒）と合わせてv75の1句が334秒かかった程度に留まり、他の99句には波及していない。

### 7-5. 3列比較表（最終版）

| 指標 | Phase1前 run100 | Phase1 smoke（10句） | Phase1 run100 |
|---|---|---|---|
| 完走句数 | 100/100 | 10/10 | 100/100 |
| ng率 | 41.5% | 9.1%（1/11） | **11.5%（13/113）** |
| forced_zatsu | 5句 | 0句 | **0句** |
| 総Ollama呼出 | 1824回 | — | 995回（−45%） |
| 所要時間 | 111.4分 | — | 64.6分（−42%） |
| 1句あたり平均レイテンシ | 66.9秒 | — | 38.8秒（−42%） |
| 300秒超過 | 5句 | — | 1句（v75、孤立タイムアウト） |
| step3_mora_rewrite 呼出 | 1215回 | — | 639回（−47%） |
| deflock率（rewrite5到達） | 74% | — | 61.9% |
| 経路1（幻の季セグメント） | forced_zatsu 5句中3句が起因 | 発生したが破綻せず吸収 | **発生（16開始中7件が露起因＋1件が誤検出）したが全件forced_zatsu化せず吸収** |
| 経路2（案F発火） | 未実装 | 0件（不発、直接テストのみで確認） | **42候補検出・12採用・最終句10句に直接反映** |

### 7-6. 案C・案F・案Aの実効性評価

- **案A（continue_line/switch_line）**：主効果は継続。幻セグメントが立っても句去・句数違反へ発展させず
  破綻を防ぐ役割は10句smokeと同じ機序で100句規模でも確認できた（v13・v89とも最終的に季継続を満たして着地）。
- **案C（ZATSU_SEED_BIAS）**：seed経由の季混入は設計どおり抑制されている（94%が雑seed、期待値と整合）が、
  露・かすみなど**ペルソナ／gaze語彙由来の混入は守備範囲外**のままで、幻セグメントの発生頻度そのものは
  下がっていない（7-2）。値としては機能しているが、経路1の根絶には別の対策（案D/E スコープ）が要る。
- **案F（shift_window_to_kigo）**：Phase1 smokeでは0件だった発火が、100句規模で42候補・12採用・
  最終句10句へ反映と、想定どおり「100句規模で初めて本番局面に当たる」が実証された。かつ副作用なし
  （モーラ精度・句切れガード同一基準）。**3案の中で唯一、定量的に「発火して効いた」ことを直接確認できた案**。

### 7-7. 次の改善候補の優先順位（所感）

1. **Step3 deflock（61.9%）**：今回のng13件中5件（38%）を占め、既に[[step3_mora_phase0]]で
   構造課題として認識済み。案C/F/Aは季局面の手戻りを減らして間接的にdeflockへも波及したが、
   deflock自体を狙った対策ではない。ng削減の伸びしろとしては最大。
2. **「露」の偶発混入（経路1の残存要因）**：季セグメント開始16件中7件を占め、Phase0で「案D/Eスコープ」
   と留保していた課題がそのまま最頻の引き金として残っている。案Aの吸収効果に頼らず発生自体を抑えたい
   なら次の優先候補。
3. **`season_from_text`のひらがな部分一致誤検出（「しも」→霜）**：新規に確認した論点。発生頻度は
   今回1件のみで実害もなかったが、同種の部分一致リスクは`SEASON_WORDS`の他の短い語（「露」「霧」等）にも
   潜在し得るため、次回Phase0調査の候補として記録に留める。
4. **ZATSU_SEED_BIASの調整**：今回の観測で0.75は設計どおり機能していると確認できたため、
   値自体を動かす優先度は現時点で低い（§3により本依頼では変更せず）。

---

## 付録：確認コマンド

```bash
# run100 の季ヒント推移
grep "SeasonHint" log/development.log | tail -60

# ng verse と季ヒントの突合（Step A 実装後）
#   observation_*.jsonl の action:"season_hint" 行と action:"retry"/"exhausted" 行を verse_no で結合
```
