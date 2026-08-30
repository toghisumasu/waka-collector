# 調査報告書：sono84 Phase 0（改訂版 v2）— ng率76.9%悪化原因の調査

- 作成日：2026-08-30
- セッション：其の八十四 Phase 0（読み取り専用・コード変更なし）
- 対象依頼書：`依頼書：sono84 Phase 0調査（改訂版）— StepwiseWakaGenerator側のng率悪化原因調査`
- 走行時HEAD：`5d4e9a6`（`feat: must_continue時に季節継続指示を明示追加 (sono84向け)`）
- ゲートチェック：`bundle exec ruby script/verify_shikimoku.rb` → **116 pass / 0 fail**（本調査中も維持）

---

## 0. 結論（要約）

**ng率76.9%は「悪化」ではない。sono84として比較対象に置かれた数値（sono79 16.7% / sono82 33.6%）は
`:direct`戦略の走行であり、今回の走行は`:waka_extraction`戦略（`StepwiseWakaGenerator`）である。
両者はパイプラインが根本的に異なり、比較が成立しない（カテゴリの取り違え）。**

今回の走行を正しいベースライン（其の七十六 Phase A の`:waka_extraction`計測）と並べると：

| 走行 | HEAD | モデル | ng率 | step3呼出 | step3構成比 |
|---|---|---|---:|---:|---:|
| 其の七十六 Phase A（8b, 7/30） | — | qwen3:8b | 84.0% | 653 | 67.4% |
| 其の七十六 Phase A（14b, 8/22） | `2e547fc` | qwen3:14b | 80.0% | 617〜630 | 70.6% |
| **今回（8/27–28）** | `5d4e9a6` | qwen3:14b | **76.9%** | **619** | **73.7%** |

**3走行の中で今回が最良のng率**であり、step3呼出回数（619）は8/22走行（617〜630）と実質同一。
n=10規模のばらつきの範囲であり、悪化を示す変化は存在しない。

`5d4e9a6`（季節継続指示）は今回の走行では**二重の意味で不発**：
1. `:waka_extraction`戦略は`renga_generator.rb:116–124`で早期returnし、変更箇所（`build_full_prompt`）へ到達しない。
2. 仮に到達したとしても、`StepwiseWakaGenerator`は自前の`directive_lines`（`stepwise_waka_generator.rb:246–263`）を持ち、`5d4e9a6`はこちらを変更していない。継続指示行はどの経路でもレンダリングされない。

真のボトルネックは**Step3（形式整形＝31音への書き換え）の低成功率**で、これは其の七十三〜七十六で既知の構造的課題。今回のstep4通過率は **8/619 ≒ 1.3%**。

---

## 1. `5d4e9a6` の差分レビュー結果

`git show 5d4e9a6` の全差分（`app/services/renga_generator.rb` のみ、+9 / −3、1ファイル）：

- `directive_lines(season_label)` に `continue_line`（`season_hint[:must_continue]` 時に
  「まだ#{season_label}を続けるべき局面です。他の季節や無季（雑）に転じないこと。」）を追加。
- `build_full_prompt` で `directive_lines` の戻り値を3要素で受け、プロンプト本文へ `#{continue_line}` を挿入。

**季節継続指示以外の変更点：なし。** StepwiseWakaGenerator・共通処理（`verse_text_analysis.rb`、
`shikimoku_checker.rb` 等）・観測スクリプトへの巻き込み変更は一切ない。コミットは主張どおり単一目的。

### 1-1. 変更が今回の走行に効かない理由（2点）

**(A) 戦略による早期return。** `renga_generator.rb#generate_tsugeku`：

```
pool = filter_pool(pool)
if @strategy == :waka_extraction
  stepwise = StepwiseWakaGenerator.new(...)
  return stepwise.generate.to_s        # ← ここでreturn。build_full_promptに到達しない
end
... 以降の5×5ループ・Socratic対話・build_full_prompt は :direct 専用 ...
```

観測スクリプト `script/observe_waka_extraction.rb:316` が `generation_strategy: :waka_extraction` を
固定で渡すため、`build_full_prompt`（＝`5d4e9a6` の変更箇所）は今回の走行で一度も実行されていない。

**(B) StepwiseWakaGenerator は別実装の `directive_lines` を持つ。**
`stepwise_waka_generator.rb:246–263` の `directive_lines` は `kigo_line` と `kinshi` の2要素のみを返し、
`must_continue` 分岐を持たない。`5d4e9a6` はこのメソッドを変更していないため、
`:waka_extraction` 経路では「継続すべき局面」であっても継続指示はプロンプトに載らない。
Step1 の季節指定は `season_label_for`（`must_switch` のみ特別扱い）＋
「#{season_label}の情趣を詠むこと。」という弱い一行に留まる。

### 1-2. 8/22走行（`2e547fc`）→ 今回走行（`5d4e9a6`）の間に入った共有コード変更の精査

`git diff 2e547fc 5d4e9a6` で `app/` 側に入った変更と、`:waka_extraction` 経路への影響：

| ファイル | 変更 | `:waka_extraction` への影響 |
|---|---|---|
| `renga_generator.rb` (+182/−46) | Step0見立て・Socratic転じ方ヒント・内部ログ計装・`initialize` へのivar追加 | **なし**。すべて早期returnより後の`:direct`コード。`initialize`追加分は加算的なivar代入のみ |
| `shikimoku_checker.rb` (±22) | `next_constraints` に `forbidden_nanaku_words` を追加（加算的） | **なし**。観測スクリプトはこのキーをRengaGeneratorへ渡していない |
| `verse_text_analysis.rb` (+10/−2) | `first_line(raw)` → `first_line(raw, maeku: nil)`。前句と逐語一致する行をスキップ | **実質なし**。Stepwiseは `first_line(...)` を `maeku:` 無しで呼ぶ（`stepwise_waka_generator.rb:105,142,159`）。`maeku: nil` のとき新旧の挙動は同一（先頭の非空行を返す／空なら `""`） |
| `stepwise_step_logger.rb` (+1) | ログ行に `maeku` フィールド追加 | ログのみ。生成ロジック無関係 |
| `ollama_client.rb` (±2) | `MODEL = ENV.fetch("WAKA_OLLAMA_MODEL", "qwen3:8b")` | 既定モデルの上書きを可能にするのみ。§4参照 |

**結論：8/22走行から今回走行までの間に、`:waka_extraction` の生成経路を変えた変更は存在しない。**

---

## 2. step3_mora_rewrite の呼出頻度（619回／10句 ≒ 62回／句）の内訳

### 2-1. これは異常頻度ではない

其の七十六 Phase A の同ステップ実測：

| 走行 | step3呼出 | step1呼出 | step1.5呼出 |
|---|---:|---:|---:|
| Phase A 8b (7/30) | 653 | — | — |
| Phase A 14b (8/22) | 617（報告値）／630（生ログ、失敗断片込み） | 167 | 87 |
| **今回 (8/27–28)** | **619** | **135** | **77** |

呼出回数はほぼ横ばい。スクリプト冒頭コメントが試算する最悪ケースは
`Step3(5) × draft(5) × 呼び出し側MAX_RETRY(5) = 125回/句`、さらにforced_zatsu救済で+α。
実測62回/句はこの半分程度で、定数設計どおりの帯域内。

### 2-2. step3 が繰り返される理由（step4判定＝Step3出力の抽出可否）

`log/stepwise_steps_20260828.jsonl` の step4 verdict 619件の集計：

| step4 判定 | 件数 | 割合 |
|---|---:|---:|
| 区切り不一致（総モーラは許容内だが 17／14 の句境界が取れない） | 188 | 30.4% |
| モーラ数が±2音を超過（内訳：29音未満が主、35音超も一定数） | 423 | 68.3% |
| **PASS（抽出成功）** | **8** | **1.3%** |

モーラ超過423件の分布（代表値）：24音56件・28音50件・27音45件・26音43件・35音40件・34音38件…
**「31音ちょうど付近」に収束せず、23〜28音（縮めすぎ）と34〜37音（縮め足りず）の二つの山**になっている。

step3 の再実行トリガー（feedback_issue）619件：

| feedback | 件数 |
|---|---:|
| N音（三十一音から2音超逸脱） | 340 |
| 区切り不一致 | 150 |
| （初回・feedbackなし） | 129 |

初回129件＝step3に到達したdraft数（step1は135回だがうち6回はStep2の「禁じ手（植物）」で弾かれstep3未到達）。
1 draft あたり step3 は平均 `619 / 129 ≒ 4.8回`＝ほぼ上限（`MAX_REWRITE_ATTEMPTS = 5`）まで回している。

### 2-3. Step3 が失敗し続ける機序（deflock）

draft単位で step3 が2回以上走った124ケースのうち：

- **45ケース（36%）は5回とも byte単位で同一の出力**。`build_mora_rewrite_prompt` は
  `feedback_note`（「※前回の書き換え「X」はN音でした。…」）を毎回注入しているが、
  モデルはそれを無視して同じ文字列を再emitしている。
- 残り79ケースは毎回わずかに変化するが（助詞を1つ落とす等）、いずれも失敗。
  変化の方向が「さらに凝縮する」ため、モーラ数はむしろ減って `24音 → 25音 → 24音…` と低位で振動する。

Step3 の実態は「意味を保ったまま 5・7・5・7・7 に**再構成**する」ではなく、
「助詞を削って**圧縮**する」動作になっている。プロンプトの
「三十一音を超えないこと」を過剰適用し、下限（短すぎも誤り）を守れていない。

代表例（verse 3, draft a1d1）：

```
Step1(31音): すみれの色に染まる格子の影 針が止まりしときわらびの音
Step3 r1〜r5（全て同一）: すみれ染め格子に影かさねて針止まりしときわらびの音
step4 r1〜r5（全て同一）: 区切り不一致
```

---

## 3. forced_zatsu エスカレーション句（verse 3・5・7）の時系列

走行ログ：`log/observation_sono76_20260827.jsonl`（RengaGenerator単位）／
`log/stepwise_steps_20260828.jsonl`（Step単位）。

### verse 3（春・`must_continue: true`）— 6 attempt → `forced_zatsu_create`

| attempt | 内容 | 結果 |
|---|---|---|
| 1 | 生成失敗（Step3→Step4を使い切りnil） | retry |
| 2 | 「遠き空風のささやき聞こ」 | **mora OK / 式目ng＝句数:春** → retry |
| 3, 4 | 生成失敗 | retry |
| 5 | 「石の上に落ちる露の重み」 | **mora OK / 式目ng＝句数:春** → exhausted |
| 6 | forced_zatsu「静かな風に揺れる葉の影」 | forced_zatsu_create |

Step1 出力は draft ごとに十分に多様（すみれ／菜の花／わらび／若草／たんぽぽ／山吹…）で、
**Step1 レベルの語彙固着はない**。失敗は Step3（同一出力の反復・区切り不一致・モーラ低位）で発生。
注目すべきは attempt 2・5 で **31音の有効な和歌が2回生成されている**こと。
どちらも A層（ShikimokuChecker）が `句数:春` で棄却した——
これは `must_continue`（季を継続すべき局面）で春の景物を含まない句が出たための棄却で、
**sono83引き継ぎ文書 §3 が指摘した既知の構造的課題そのもの**。
`5d4e9a6` はまさにこれを狙った変更だが、§1-1(B) のとおり `:waka_extraction` 経路には効いていない。

### verse 5（秋・`must_continue: true`）— 7 attempt → `forced_zatsu_create`

attempt 1〜5 は**すべて「生成失敗」**（Stepwise が nil を返す）。
Step1 出力は多様（もみじ・雁・時雨・菊・萩・白露…）だが 15〜45音とばらつき、
Step3 が一度も 31音有効句に到達できなかった。
forced_zatsu：attempt 6「風の音たなびく木の実に光りわたる」（mora ng）→
attempt 7「夢見る蝶が舞う空を越えて」で `forced_zatsu_create`。

### verse 7（雑）— 8 attempt → `forced_zatsu_mora_ng`

attempt 1〜5 すべて「生成失敗」。
**Step1 に軽度の話題固着**：ほぼ全 draft が「石の上に…」「露の…」で始まる
（seed は毎回異なるのに景物が石・露へ収束）。Step3 は例によって未収束。
forced_zatsu が**強い語彙 deflock**：

```
attempt 6: 夢の果てに散る花の香り漂う
attempt 7: 夢の果てに光り出す星の海
attempt 8: 夢の果てに灯る星の光り尽きる   → forced_zatsu_mora_ng で確定
```

「夢の果てに」「星」「光」で完全に固着。これは forced_zatsu 救済経路
（`OllamaClient.chat`、既定モデル）の既知傾向で、7/30 8b報告の
「末尾『静けさを呼ぶ』連続固着」と同種。

### 「同じ失敗の反復か／毎回違う失敗か」

- **Step1**：verse 3・5 は多様、verse 7 は話題（石・露）へ収束。全体としては語彙 deflock は限定的。
- **Step3**：**同じ失敗の反復**。feedback を無視した同一出力の再emit（draft の36%）か、
  同方向（さらに凝縮）の微変化で低位モーラを振動。プロンプト改善なしには抜けられない。
- **forced_zatsu**：verse 5・7 で「夢／果て／星／光」の強い語彙 deflock。

---

## 4. sono82走行時と今回走行時の Ollama 状態の差

### 4-1. 呼び出しレベルの実測（`log/observation_sono76_calls_20260827.jsonl`、840件）

| 指標 | 今回 | 8/22 Phase A 14b |
|---|---|---|
| 総呼出 | 840 | 883（失敗断片込み） |
| `ok:false`（例外・タイムアウト） | **0** | 0 |
| 180秒タイムアウト超過 | **0** | 0（8b では5回） |
| step3 平均レイテンシ | 2.9秒 | 2.9秒 |
| step1 平均レイテンシ | 〜4–5秒 | 4.7秒 |
| kind内訳 | step3 619 / step1 135 / step1.5 77 / forced_zatsu 9 | step3 630 / step1 167 / step1.5 87 / forced_zatsu 9 |

**呼び出し単位のレイテンシ・成功率は8/22走行と区別がつかない。**
Ollama無応答ハング・モデルのアンロード／再ロードによる極端な遅延は、
840呼出を通じて1件も観測されていない（すべて数秒で応答）。
1句あたり平均283.6秒・最大622.6秒という数値は、**1句あたりの呼出回数が多い（平均84回）ことの帰結**であって、
1呼び出しが遅くなったわけではない。

なお `:direct` の sono82（`renga_internal_..._sono82_...`）は内部Socraticループのraw計装ログで、
Ollama呼び出し単位の所要時間を記録していないため、**呼び出しレイテンシの直接比較はできない**。
比較可能なのは同じ観測スクリプトを使った其の七十六 Phase A 走行のみ（上表）。

### 4-2. 実験条件の差として特定できたもの

- **HEAD**：8/22 = `2e547fc`、今回 = `5d4e9a6`（間の共有コード変更は §1-2 で影響なしと確認）。
- **`WAKA_OLLAMA_MODEL` 環境変数**（`be056e1` で新設）：設定されていれば
  `OllamaClient::MODEL`（＝ forced_zatsu 救済経路 `OllamaClient.chat` が使うモデル）が上書きされる。
  今回の走行でこの変数が `qwen3:14b` に設定されていたかは**ログからは確認できない**。
  設定有無で forced_zatsu 句の出来は変わり得るが、`total_ng` / ng率の集計は
  正規経路（Step1〜Step4）の試行が支配的なため、影響は小さい。
- それ以外（同時実行プロセス、直前操作、モデルのプリロード状況）を示す情報はログに残っていない。
  ファイルタイムスタンプ上、走行は 2026-08-28 06:41〜07:28 JST に連続実行されており、
  途中で長時間の中断・再開が挟まった形跡はない。

---

## 5. 調査から導かれる仮説

**この時点では修正は行わない。** 以下は優先度順の仮説。

### 仮説A（本命）：悪化ではなく、比較のカテゴリ取り違え

依頼書 §1 の比較表は `:direct`（sono79/82/83）と `:waka_extraction`（今回）を並べている。
両者は別パイプライン。今回の走行はバッチ名 `sono76_20260827` が示すとおり
**其の七十六 Phase A（`:waka_extraction` 方式のレイテンシ・コスト観測）の再走行**であり、
sono79→83 の `:direct` 改善ラインの続きではない。
正しいベースライン（Phase A 14b: ng率80.0%、step3 617）と比べると、
今回（76.9%、step3 619）は**むしろ僅かに良い**。n=10 のばらつきで説明がつく。

### 仮説B：`5d4e9a6` は今回の走行に対して完全に不発

§1-1 の2点（戦略による早期return＋Stepwise側の別実装 `directive_lines`）により、
季節継続指示はプロンプトに載っていない。ng率との因果はゼロ。
（依頼書 §0 の前提を、コードと走行ログの両面から追認した。）

### 仮説C（真の課題）：Step3 形式整形の低成功率＝既知の構造的ボトルネック

step4 通過率 1.3%（8/619）。Step3 が「5・7・5・7・7 への再構成」ではなく
「助詞を削る圧縮」として振る舞い、23〜28音へ落ちるか、prose のまま句境界が取れない。
feedback ループは無効（draft の36%で同一出力を再emit）。
其の七十三〜七十六で繰り返し指摘されてきた課題であり、モデルを 8b→14b にしても
「1句確定までに必要な Step3 反復回数」は改善していない（8/22報告の結論と一致）。

### 仮説D：`must_continue` 局面での A層棄却（副次的だが `5d4e9a6` の本来の標的）

verse 3 で 31音の有効句が2回生成されながら、いずれも `句数:春`（季継続違反）で棄却された。
`:waka_extraction` 経路の季節指示は弱く（`StepwiseWakaGenerator#directive_lines` は
`must_continue` 分岐を持たない）、`5d4e9a6` の意図した補強がこの経路には適用されていない。
`:direct` 側の sono83 §3 と同じ現象が `:waka_extraction` 側でも起きている。

### 仮説E：forced_zatsu 救済経路の語彙 deflock

verse 7 で「夢の果てに／星／光」に固着。既定モデル（8b または `WAKA_OLLAMA_MODEL` 上書き値）を使う
`OllamaClient.chat` 経路の既知傾向。7/30 8b報告と同種で、新規事象ではない。

### 実行環境差（偶発的なLLM出力の悪さ）について

呼び出し単位では 8/22走行と有意差なし（レイテンシ・成功率・タイムアウト0）。
「再現性の問題（Ollama側の状態悪化）」を示す証拠はログ上に**ない**。
n=10 の試行数ゆえ、句レベルの結果（どの句が forced_zatsu に落ちるか）は
seed 抽選と Step1 出力の運に大きく左右されるが、これは方式固有の分散であって
実行環境の劣化ではない。

---

## 6. 完了条件チェック（RC=0）

- [x] `docs/investigation_sono84_phase0_v2.md` を生成し、依頼書 §4 の4項目すべてを記載
  - [x] `5d4e9a6` の差分レビュー結果（季節継続指示以外の変更点の有無）→ §1
  - [x] step3_mora_rewrite 呼出理由の内訳（集計表）→ §2
  - [x] verse 3・5・7 の時系列比較（プロンプト／LLM出力／失敗パターンの変化有無）→ §3
  - [x] sono82（≒其の七十六 Phase A）実行時との環境差の有無 → §4
  - [x] 調査から導かれる仮説（この時点で修正なし）→ §5
- [x] `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- [ ] git：本ドキュメント1件のみをコミット（コミット操作は本報告書の内容確認後）

## 付録：一次資料

- コミット：`git show 5d4e9a6`、`git diff 2e547fc 5d4e9a6`
- 走行ログ（今回、バッチ `sono76_20260827`／gitignore対象・非コミット）：
  - `log/observation_sono76_20260827.jsonl`（40行、RengaGenerator単位、verse 0–10）
  - `log/observation_sono76_calls_20260827.jsonl`（840行、Ollama呼出単位）
  - `log/stepwise_steps_20260828.jsonl`（1711行、Step単位）
- ベースライン：`docs/phase_a_20260822_其の七十六_waka_extraction_14b_report.md`、
  `docs/phase_a_20260730_其の七十六_waka_extraction_report.md`
- `:direct` 側の関連課題：`docs/handover_20260826_其の八十三.md` §3、`docs/analysis_20260825_sono82_ng.md`
- 対象コード：`app/services/renga_generator.rb`（早期return: 116–124行 / `directive_lines`: 434–457行）、
  `app/services/stepwise_waka_generator.rb`（`directive_lines`: 246–263行 / Step3: 153–171行）、
  `script/observe_waka_extraction.rb`
