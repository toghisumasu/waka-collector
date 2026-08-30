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

## 付録：確認コマンド

```bash
# run100 の季ヒント推移
grep "SeasonHint" log/development.log | tail -60

# ng verse と季ヒントの突合（Step A 実装後）
#   observation_*.jsonl の action:"season_hint" 行と action:"retry"/"exhausted" 行を verse_no で結合
```
