# waka-collector 現状認識（understanding.md）

## 2026-11-08 版

作成方法：コード・README・設定・docs を読み、ゲートチェックと rspec を実行して裏を取った。
記号：**【確認済み】** ファイル・実行結果で裏が取れた／**【推測】** コードから読んだが未確認／**【未決】** 不明、または人間の判断が要る。
推測を確認済みに混ぜない。docs の記述を引用しただけのものは「docs記載（再検証なし）」と明記する。

---

## 1. 目的と現在のマイルストーン

### 目的
- **【確認済み】** 古典連歌（百韻）を AI 支援で作成・検証する Rails アプリ。式目判定は決定論の Ruby（A 層 `ShikimokuChecker`）、語彙フィルタは YAML 辞書（B 層）、付句生成だけを LLM（C 層、Ollama）に任せる三層構造。根拠：`CLAUDE.md`、`README.md` §アーキテクチャ。
- **【確認済み】** 本番稼働の生成方式は `:direct`（既定）。`:waka_extraction`（`StepwiseWakaGenerator`）は実装済みだが本番では使われていない。根拠：`README.md` §付句生成の2方式、`app/services/renga_generation_service.rb` が `generation_strategy` を渡していない。
- **【確認済み】** 本番経路は `RengasController#create` → `GenerateRengaJob`（非同期）→ `RengaGenerationService#call` → `RengaGenerator#generate_tsugeku` → `ShikimokuChecker` で最終検証。

### 現在のマイルストーン
- **【確認済み】** 直近のコミットは 2026-11-02 の `863f7d0`（OllamaClient の temperature を `options` 内へ移す「M-7a」）と 11-03 の参考文献一覧。それ以前（9月末〜10月）は、モデル比較（M 系）、辞書・式目照合（G・千句準拠の辞書修正）、水無瀬三吟の付合ペアを qwen3:8b で採点する S-0〜S-2a の系列。根拠：`git log`。
- **【確認済み】** 直近の 100 句走行ログは `log/renga_internal_observe_rg_20260929.jsonl`（verse_no 最大 100）。以後、走行ログの更新はない。
- **【推測】** いまの主題は「付合の距離（近・中・遠）を機械で測れるか」の検証（S 系）。根拠は `docs/依頼書_S2a_*.md` と `tmp/minase_*` 群だけで、S-3/S-4 以降の依頼書は見つかっていない。
- **【未決】** 次のマイルストーンは何か。S-4（8b への 3 択実験）・S-1（Jev）・S-3、M-7 系の続き、`qwen38-27b-q2k-waka` のハング調査のどれを優先するか。

---

## 2. 未知・データ・条件

### 未知（これから作る・直すもの）
| 項目 | 状態 | 区分 |
|---|---|---|
| 付合の距離を測る指標 | bui 距離は手ラベルと ρ=0.411、qwen3:8b の季軸は ρ=0.458 だが S-0c で再現せず（0.150）。恋→恋の除外・置換検定は S-2a の依頼書段階 | docs記載（`docs/依頼書_S2a_*.md`）。スクリプトは未コミットで私は再実行していない |
| `qwen38-27b-q2k-waka` が `tenji_kata_hint` でハングする件 | think:true は悪化要因（n=10）と記録。付句生成本体での効果は未検証 | docs記載（`docs/llm_behavior_notes.md` #9 注） |
| temperature 修正（863f7d0）の効果 | 修正前は `temperature` が `options` の外にあり無視されていた「可能性」。修正後に挙動が変わったかは未計測 | **【未決】**（`docs/learnings.md` は「未検証」と明記） |
| 複合語（月夜・霜夜 等）が部立・七句去物・OverlapGuard をすり抜ける問題 | 対応は未実施 | docs記載（`docs/learnings.md`）。再現確認は今回していない |
| Step3 の 31 音収束、A 層到達率、`best_match` 自己強化ループ | `:waka_extraction` 側の既知課題。本番は `:direct` のため優先度は **【未決】** | `README.md` §既知の課題 |
| 一座 N 句物（二〜五句）・`ichiza_limit`、「同字」判定 | 未実装 | docs記載（`docs/research_shikimoku_dictionary_check_20261012.md`）。コード側は今回未確認 |

### データ（入力・既存資産）
- **【確認済み】** 辞書：`app/data/bui_dictionary.yml`、`kuzari_rules.yml`、`kukazo_rules.yml`、`ichiza_ichiku_words.yml`、`nanaku_gomono_words.yml`。瀬田 2016 版は別ファイル（`*_seta2016.yml`）で、本番は使わない（`dcaa3ad`）。
- **【確認済み】** 先行作品データ：`renga_works` / `renga_work_verses` テーブル（水無瀬・湯山など）、`docs/reference/*.csv`（古規・去嫌一覧）、`docs/minase_*.md`。
- **【確認済み】** seed 供給元は `wakas` テーブル。MeCab ユーザー辞書は `dict/user_entries.csv` → `dict/user.dic`。
- **【確認済み】** 観測ログ `log/*` は `.gitignore` 対象（git に残らない）。`tmp/` も原則対象だが、S-0 系の採点 raw と手ラベル 4 ファイルだけは追跡対象に例外指定されている（`.gitignore`）。
- **【確認済み】** 未追跡ファイル：`script/` の分析スクリプト 11 本と、`docs/` の調査メモ 3 件（`git status`）。

### 条件（制約・ルール）
- **【確認済み】** 作業前ゲートチェック `bundle exec ruby script/verify_shikimoku.rb` が全 pass であること。失敗時は作業禁止（`CLAUDE.md`）。
- **【確認済み】** LLM に音数・式目・部立・距離を判定させない（`docs/llm_behavior_notes.md` §2）。
- **【確認済み】** 観測系スクリプトは `bin/rails runner` で実行する。既定モデルは `qwen3:8b`（`app/services/ollama_client.rb:13`）で、`WAKA_OLLAMA_MODEL` を指定しないと 8b が走る。
- **【確認済み】** 本番 100 句走行はユーザーが手動で起動する。こちらは調査・コード修正まで（メモリ記録）。
- **【確認済み】** `rm` などの書き込み系にワイルドカードを使わない（メモリ記録）。
- **【確認済み】** Ollama は現在 `localhost:11434` で応答し、`qwen3-14b-16k` と `qwen38-27b-q2k-waka` を含む複数モデルが登録されている（今回 `curl /api/tags` で確認）。

---

## 3. 誰が何を知っているか

### 表
| 主体 | 見えている情報 | 見えていない情報 | 他者はそれを知っているか |
|---|---|---|---|
| **人（あなた）** | 連歌の美学、手ラベル（水無瀬 30 ペア）、ブラウザでの生成結果、走行の起動と結果 | 内部試行ログの全体像（1 句あたり平均 12.5 試行。docs記載）。検証が黙って通った箇所 | 手ラベルの基準は LLM もコードも知らない。私はファイル上の結果しか知らない |
| **LLM（C 層）** | そのときのプロンプトだけ。前句、seed、禁止部立、季ヒント、展観ヒント、直近履歴の一部 | 式目の全体、百韻全体の進行、自分の過去出力（履歴は Ruby が選んで渡した分のみ）、音数の真値 | 式目違反かどうかは Ruby が判定する。LLM は結果を知らず、フィードバック文で間接的に知るだけ |
| **コード A 層** `ShikimokuChecker` | 履歴（直近最大 9 句）と候補の `bui`・`season`・`word`・`plant_type` | 辞書に載っていない語、MeCab が複合語 1 語にした語の内側、直近 9 句より前の句 | 辞書の穴は誰も自動では知らせない。docs と調査報告を人が読んで知るだけ |
| **コード B 層** `BuiDictionary` / MeCab | 辞書登録語と MeCab のトークン | 未登録語（`bui: []` を返し、エラーにならない）。複合語の内側 | 同上 |
| **コード** `KuValidator` | MeCab の読みからの音数 | 読みの誤りがあっても自分では気づけない（`user.dic` 頼み） | 誤りは人かログ分析で発見される |
| **Ollama（外部）** | 受け取った prompt と `options` | アプリの目的、式目、他のリクエスト | アプリ側は Ollama のモデル実体を `Modelfile` 経由で知るだけ。別名と実体の対応は docs に手書き |
| **VPS・DB（外部）** | `rengas`（全試行）と `renga_verses`（成立句） | ログファイル（gitignore）、辞書の版 | **【未決】** VPS 上のコードと辞書がローカル HEAD と一致しているかは今回確認していない（メモリ上は稼働中の記録あり、今回の確認なし） |
| **私（このセッション）** | 今回読んだファイルと実行結果 | 過去セッションで何を見たか（メモリ記録と docs の範囲のみ）、VPS の現況、`log/` の全内容 | 私の認識は本書にまとめた。メモリの記述は再検証していない限り「docs記載」扱い |

### 補足
- **【確認済み】** 本番経路の `RengaGenerator` 内部ループ（5×5）には `ShikimokuChecker` が入っておらず、式目判定は `generate_tsugeku` を呼び終えた後の `RengaGenerationService` が行う（`renga_generator.rb:253` のコメント、`renga_generation_service.rb`）。つまり LLM は「どの式目に違反したか」を、内部ループ内ではフィードバックされない（外側の再呼び出しは観測スクリプト側）。
- **【確認済み】** `GenerateRengaJob` は式目 NG 時に `status: "failed"` にして終わる。再生成はしない。

---

## 4. 検証の仕組み

### 機械的に検証している箇所
- **【確認済み】** ゲートチェック `script/verify_shikimoku.rb`：今回実行して **121 pass / 0 fail**。合成ケース（句去・句数・長短交互・定座・一座一句物）、水無瀬三吟の統合スキャン、回帰テスト、MeCab ユーザー辞書の読み込みを含む。
- **【確認済み】** `KuValidator`：音数は MeCab の読みからの決定論。
- **【確認済み】** `RengasController#create` は前句自体を `ShikimokuChecker` にかけ、`RengaGenerationService` は付句候補に `all_violations` + `ichiza_violations` + `chotan_violations` をかける。
- **【確認済み】** `OverlapGuard`（前句との内容語 Jaccard、閾値 0.111）と echo・固着・履歴重複の判定は Ruby で行う（`renga_generator.rb` 内部ループ）。
- **【確認済み】** rspec（`spec/services`）に、`StepwiseWakaGenerator`、`OverlapGuard`、`ShikimokuChecker`（湯山）、`RengaMatchScore` などのテストがある。

### 自己申告・目視・手作業に頼っている箇所
- **【確認済み】** 百韻全体の出来は目視。`docs/hyakuin_*.html` や `log_to_html.rb` の出力を人が読む。
- **【確認済み】** 手ラベル（近・中・遠）は人の主観が基準。
- **【確認済み】** 観測結果の集計は「使い捨てスクリプト（scratchpad）」で行われた例がある（`docs/observation_20260929_*.md` 冒頭）。再現するスクリプトが git にない。
- **【確認済み】** ゲートチェックの期待値は人が手で書く。過去に辞書変更後の期待値更新漏れが起き、`10a3fe5` 時点で 120 pass / 1 fail だった（`docs/research_shikimoku_dictionary_check_20261012.md`）。その後 `1422a06` で修正済みで、今回は 121/0。

### 黙っていても通ってしまう箇所
1. **【確認済み】** `style_check_result` は `RengaGenerationService#call` が常に `{ "result" => "ok", "issues" => [], "breakdown" => [] }` を固定で返す。式目違反なら例外で失敗扱いになるので「ok」自体は矛盾しないが、DB に残る値は検証結果の記録ではなく定数である。
2. **【確認済み】** 未登録語と複合語：`BuiDictionary#detect_all` が `[]` を返しても例外にならず、句去・句数ルールが働かないまま通る。複合語の例は `docs/learnings.md`。再現は今回していない。
3. **【確認済み】** 月・花の定座：`teiza_tsuki_violations` / `teiza_hana_violations` は `scan_chain_with_chotan` からだけ呼ばれ、本番経路の `all_violations` には入っていない。`app/` 内に他の呼び出し元はない（grep で確認）。ゲートチェックは定座を試験しているので「検証済み」に見えるが、本番生成では適用されない。
4. **【確認済み】** `RengaChecker`（LLM による式目チェック）は `app/services/renga_generation_service.rb` に名前が残るが、実際の呼び出しは `ShikimokuChecker` に置換済み。コメントで経緯が分かる。ただし `renga_checker.rb` 本体と `ollama_tools.rb` は残っている。`llm_behavior_notes.md` は「現在も未呼出」と記載。
5. **【確認済み】** `StepwiseStepLogger` は書き込み失敗を握りつぶして `Rails.logger` に警告を出すだけ。ログが欠けても生成は進む。
6. **【確認済み】** 文書の数値が古い：`CLAUDE.md` は「55 pass」、`README.md` は「116 pass」と書くが、実測は 121。rspec も `README.md` は「135 examples / 5 failures」と書くが、実測は **173 examples / 19 failures / 20 pending**。内訳は `rengas_controller_spec` 11、`waka_spec` 3、`wakas_spec` 2、`stepwise_step_logger_spec` 1、`stepwise_waka_generator_spec` 2。`README.md` は失敗を「Waka ファクトリの既知バグ」だけと説明しているが、実際には他の 14 件がある。
7. **【確認済み】** `StepwiseStepLogger` の spec は `step3` を期待するが、実際のログは `["step1","step2","step1.5","step4"]`。仕様の変化にテストが追従していない可能性がある（原因は **【推測】**）。
8. **【未決】** `rengas_controller_spec` の 11 件は、メモリ上「メソッド移設後に未更新」とされる。今回は原因まで追っていない。

---

## 5. このプロジェクト固有の問い（ポリア 4 段階）

各マイルストーンの開始時・終了時に使う。

1. **理解：その判定は本番経路に入っているか。**
   ゲートチェックで pass するルール（定座、`scan_chain_with_chotan`、`next_constraints` など）が、`RengaGenerationService#call` から実際に呼ばれているかを `grep` で確かめたか。今回の定座がその例（検証と本番の乖離）。
2. **計画：何を 1 変数として動かすか。**
   モデル、`OverlapGuard`、`num_predict`・`repeat_penalty`、temperature、辞書の版を同時に変えていないか。`docs/observation_20260929_*.md` は 4 要因が同時に変わっており、秋 56% の原因を切り分けられない。変えるのは 1 つ、比較対象のログは同一条件か。
3. **実行：LLM に自己評価をさせていないか。**
   新しい指標（距離スコア、採点）が LLM の出力を信頼していないか。S-0b で季軸だけに相関が出て S-0c で消えたように、指示文を変えただけで結果が動くものは、決定論の系列（bui 距離など）と並べ、置換検定で偶然を除いてから採用するか。
4. **実行：辞書の穴が「違反なし」として通っていないか。**
   `bui: []` の句、複合語、未登録語が何件あり、それぞれが検証をすり抜けているのか。100 句走行の後に未登録語の一覧を出すか。
5. **振り返り：数字の出どころは再現できるか。**
   集計に使ったスクリプトは git にあるか、`log/` のどのファイルか（gitignore 対象）、`CLAUDE.md` / `README.md` の期待値は更新したか。ゲートチェックと rspec の件数は文書とずれていないか。

---

## 6. 未決事項（あなたへの質問）

1. 次のマイルストーンは何ですか。S-4 / S-1 / S-3、M-7 の続き、`qwen38-27b-q2k-waka` のハング調査のうち、優先は？
2. 本番モデルは何ですか。`ollama_client.rb` の既定は `qwen3:8b` のままですが、VPS が実際に使っているモデルは何か。
3. VPS 上のコード・辞書は、ローカル HEAD（`cbcb0fe`）と一致していますか。千句準拠の辞書修正（10/12）や `OverlapGuard` は反映済みですか。
4. 月・花の定座（`teiza_*`）を本番の `all_violations` 経路に入れる予定はありますか。それとも意図的に外していますか。
5. `README.md`（116 pass・135 examples/5 failures）と `CLAUDE.md`（55 pass）の数値を、実測（121 pass、173 examples/19 failures）に更新してよいですか。
6. rspec の失敗 19 件のうち、`rengas_controller_spec`（11）と `stepwise_*`（3）は直しますか、放置しますか。
7. `style_check_result` に固定値を入れている現状を、実際の検証結果（違反 0 件の確認、検出した部立など）の記録に変えたいですか。
8. 9/29 の 100 句走行（`bonsai2-waka`、秋 56%）と 9/25 の 14b 走行のうち、比較基準にするのはどちらですか（`docs/observation_20260929_*.md` が確認を求めたまま）。
9. 未追跡の `script/` 11 本と `docs/` の調査メモ 3 件はコミットしますか。`docs/kiyo_*.pdf` などは著作権配慮で対象外のままでよいですか。
10. temperature 修正（`863f7d0`）の前後比較の走行は、いつ、どのモデルで行いますか（走行の起動はあなたの手動）。

---

## 7. 2026-11-19 追記：stale spec 依頼書の実施結果

### 計画から外れた点
- 2026-11-19: 依頼書（`fix/stale-specs` で 19 failures を直す）の前提と実態がずれていた。失敗19件は `53a482f`（`ci/run-rspec` 上、2026-11-17）で既に解消済み（`main` にも入っていた）で、開始時点の rspec は `173 examples, 0 failures, 20 pending`。`fix/stale-specs` は `main` と差分なし。そのため新規の修正コミットは作らなかった。
- 2026-11-19: 当初「`53a482f` は main 未マージ」と報告したのは `git branch --contains` の出力の読み違い（誤報）。訂正済み。
- 2026-11-19: 依頼書は Ruby 3.3.6 前提だが、実機・`.ruby-version` とも 3.3.13（`771b2eb` で更新）。
- 2026-11-19: 「ゲートチェックのテスト」用語の取り違えと同種で、依頼書の数値（173/19/20）は `53a482f` 適用前の古い実測値だった。

### ③の調査結果（メソッドの移動先）
- `fetch_verse_history` / `build_verse_history` は削除でなく移動。`a0daaa9`（GenerateRengaJob と RengaGenerationService 新設）と `bfe6a14`（RengasController#create 非同期化）で `app/services/renga_generation_service.rb` へ。`build_mecab` は `renga_generator.rb:330` にあり、RengaGenerationService 側は `RengaGenerator::USER_DIC` を再利用。
- spec は `spec/services/renga_generation_service_spec.rb` に移設済み（`53a482f`）。旧 `rengas_controller_spec.rb` の11件はここに引き継がれた。

### D-41-1 回帰テストの検知力（2026-11-19 実測）
- `build_verse_history` の `if chain.empty?` を `if true` に一時変更（二重カウント再現）→ 同 spec は `11 examples, 5 failures`（赤）。復元（`git checkout`）後は全体 `173 examples, 0 failures, 20 pending`。
- 検知した5件: history の奇偶パターン(:48)、9句上限(:67)、verse30(:123)、verse34(:131)、verse21(:151)。
- **検知できなかった（強化前）**: verse56相当は二重カウントがあっても緑だった。原因は、候補「しぐれの音に心の雨やと願う」を現行の `season_from_text` が冬と判定し、秋の連続上限（max=5）が検査対象にならなかったため。
- **強化後（2026-11-19、`test/strengthen-verse56`）**: 候補の季をRun5ログの違反ラベル「句数:秋」に合わせて明示（`season: "秋"`）。実測: 二重カウント再現（`if chain.empty?`→`if true`）で verse56 が赤（`streak=6, max=5, kukazo_over`）、既存5件も赤（計6件/11例）。復元後は緑。
- **未決**: Run5当時に候補が「句数:秋」と判定された理由。「しぐれ」は其の十九から冬語彙なので、本文判定なら当時も冬のはず。候補の季をseed等から渡していた可能性があるが、手元のログでは確認できず推測のまま。

### 次に引き継ぐ知識
- §6 の問6（rspec失敗19件を直すか）は解決済み。rspec は 0 failures。README/CLAUDE.md の数値（問5）は rspec が 173 examples/0 failures、verify_shikimoku が 121 pass へ更新が必要。
- pending 20件は未着手。`WAKA_UNIDIC_DICDIR` 未設定分と scaffold の空 view spec が主。CI での環境変数設定は決定済みだが未実施。
- 2026-11-19 訂正: `53a482f` は `main` に既に入っていた（当初「未マージ」と誤認）。`ci/run-rspec` の CI 3コミット（31e69d8/771b2eb/de49a49）を `main` へ fast-forward で取り込み済み（ローカルのみ・未push、`origin/main` より5コミット先行）。GitHub 上の CI 結果は `gh` 未導入のため未確認。

### 計画から外れた点（verse56強化）
- 2026-11-19: 依頼書は「実データの再現に近づける」前提だったが、実データの候補文を本文判定すると冬になり、同じ文では二重カウントを検知できない。やむを得ず候補の季を明示する形にした（実データのテキスト・履歴は維持）。Run5当時の季判定経路は未決。
- 2026-11-19: 依頼書手順1の「git statusクリーン」は、未追跡ファイルが残るため厳密には満たさない（追跡対象はクリーン）。
