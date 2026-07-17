# waka-collector 設計判断記録

**位置づけ:** 「なぜそう作ったか」を残す生きた仕様書。  
引き継ぎ文書とは別に、設計判断が生まれるたびにここに追記する。  
**更新:** 新しい判断は上に追記する（最新が先頭）。

## 其の四十四（2026-07-17）追記

---

### D-44-1　next_constraints（forbidden_bui/season_hint）をRengaGeneratorへ配線

**判断：`RengasController#create`で、`ShikimokuChecker#next_constraints`が算出する
`forbidden_bui`/`season_hint`を、生成前に`RengaGenerator`のconstraintsへ渡すよう配線した
（D-33-1の人間承認プロセスに従い、修正案[diff]を人間に提示・承認を得てから実装）。**

**背景：** 其の四十一(T5)の調査で、`RengaGenerator`側（`filter_pool`・`kigo_hint`・
`build_full_prompt`）は`@constraints[:forbidden_bui]`・`@constraints.dig(:season_hint, :current)`・
`season_hint[:must_switch]`/`[:must_continue]`を消費する実装が既に完成しており、
`ShikimokuChecker#next_constraints`の戻り値形式ともビット単位で一致していたにもかかわらず、
本番経路（`RengasController#create`）にも観測スクリプト（`script/observe_production_hyakuin.rb`）
にも呼び出し側の配線が一切なく、`script/dryrun_hyakuin.rb`（検証ハーネス）のみが使用していた
（`docs/observation_analysis_其の四十一.md` §5）。すなわち欠けていたのは
`RengaGenerator`本体ではなく、呼び出し元でconstraintsを組み立てる部分だけだった。

**修正内容（其の四十四）：**
`app/controllers/rengas_controller.rb#create`で、`nm`/`bui_dict`/`history`
（`build_verse_history`）/`checker`（`ShikimokuChecker.new`）の構築を、
`RengaGenerator.new`呼び出しより**前**に繰り上げた。従来はこれらの構築が
生成**後**（付句の式目検証のためだけ）に行われていたため、`next_constraints`
（historyが必要）を生成前に計算する余地がなかった。構築順序を変えた上で
`next_constraints = checker.next_constraints(history)`を呼び、
`constraints: { verse_history:, forbidden_bui:, season_hint: }`として
`RengaGenerator.new`に渡す。生成後の式目検証（`all_violations`等）は同じ
`history`/`checker`を再利用し、二重構築は発生しない。`RengaGenerator`本体・
`ShikimokuChecker`本体・`build_verse_history`（D-41-1修正部分）・
`build_full_prompt`冒頭指示文（D-19-1）は無変更。

`script/observe_production_hyakuin.rb`への同様の配線は、人間の判断で今回は
対象外とした（本番経路[`RengasController`]の変更を優先し、観測スクリプトは
現状のまま）。そのため同スクリプトでは引き続き`forbidden_bui`/`season_hint`が
空のまま扱われる。次回、観測での効果測定が必要になった際に改めて配線するか、
使い捨ての検証スクリプトで代替するかを判断すること。

**動作確認（其の四十四T5）：** `script/observe_production_hyakuin.rb`を変更しない方針の
ため、使い捨ての検証スクリプト（リポジトリ非管理、Renga生成15句分）で、実際の
`RengaGenerator`インスタンスの`@constraints`が期待通りの値になっていること
（配線OK＝15/15）、forbidden_bui発火時（"植物"、複数回）に生成句のbuiと
重複した回数が0/15であること、season_hintのmust_continue（4回）・
must_switch（2回）が正しく発火し、must_switch発火直後に実際に季節転換
（秋→春）が起きることを確認した。`bundle exec ruby script/verify_shikimoku.rb`は
88 pass/0 fail維持、`spec/controllers/rengas_controller_spec.rb`は既存の
D-41-1回帰テストを含め11 examples全成功（`create`アクション自体の順序変更は
既存specの対象外の私メソッドテストには影響しない）。

**次のステップ：** 本配線による式目ng却下率・generate_fail率への効果は、
次回の其の三十九系列観測（`script/observe_production_hyakuin.rb`）で改めて
測定する必要がある（今回のT5は配線の正しさの確認に限定し、大規模な効果測定は
対象外）。その際、観測スクリプト側にも同様の配線を行うかどうかは別途判断する。

---

## 其の四十一（2026-07-17）追記

---

### D-41-1　build_verse_history前句二重カウントバグ

**判断：其の四十二で修正済み。`build_verse_history`内のみのスコープで、
`chain`が非空のときは`maeku`エントリの再追加を行わないよう修正した
（D-33-1の人間承認プロセスに従い、修正案[diff]を人間に提示・承認を得てから実装）。**

**修正内容（其の四十二）：**
`app/controllers/rengas_controller.rb#build_verse_history`の末尾、
`history << { ... }`（maekuエントリの追加）に`if chain.empty?`ガードを追加。
`chain`が非空のとき、その末尾要素（`previous_renga_id`自体＝`maeku`と同一句）は
既に`chain.each_with_index.map`で`history`に含まれているため、追加の`maeku`
エントリは不要（むしろ重複の原因だった）。`chain`が空（`previous_renga_id`が
blank等）のときのみ、従来通り`maeku`エントリを追加する。変更は1行のみ。
`fetch_verse_chain`の呼び出し・`limit: 9`（其の三十七で確定した`chain.size<9`の
上限）には一切触れていない。

**回帰テスト（`spec/controllers/rengas_controller_spec.rb`、其の四十二で追加）：**
其の四十一で特定した誤却下8件（verse30×2「句数:冬」、verse34×5「句数:秋」、
verse56×1「句数:秋」）に対応する実データ（同一テキスト）で、修正後は
`kukazo_violations`が空（誤却下解消）になることを検証。あわせてkukazo_under系
（verse21相当）の判定結論が修正前後で変わらないことも検証。既存テスト2件
（verse_type奇偶交互パターン・9句上限）は、重複バグに依存した期待値
（chain 3件+1件=4件、chain 9件+1件=10件）を、修正後の正しい期待値
（3件、9件）に更新した。全11 examples成功。`verify_shikimoku.rb`は
88 pass / 0 fail維持。

**背景：**
其の四十一（`docs/observation_analysis_其の四十一.md` §4）で、Run5ログ
（`sono39_run5_20260716`）のng却下頻度・違反種別分布を分析した際に発見した。
`RengasController#build_verse_history`は`fetch_verse_chain(previous_renga_id, limit: 9)`
で履歴を取得しているが、このSQL（再帰CTE、`WHERE id = ?`起点）は`previous_renga_id`
自体（＝直前句`maeku`と同一の句）を結果の末尾に含む。その直後に
`history << { ..., season: season_from_text(maeku), ... }`で同じ句をもう一度
明示的に追加しているため、**直前の1句が常にhistory内で2回連続してカウントされる。**

**D-19-5との関係（別の不具合であることの整理）：**
D-19-5は元々「RengaChecker（LLMベース、其の三十八でShikimokuCheckerに置換済み・D-38-1）が
前句・付句の2句だけを見て句数を誤判定する」という問題として記録された。其の四十一の
調査で、現行の`ShikimokuChecker#kukazo_violations`は`history`（複数句の配列）を
受け取り`current_season_streak`で末尾から正しく遡る設計であり、**2句しか見ないという
原初の制約はコード上もはや存在しないこと**を確認した。D-41-1は、ShikimokuChecker自体の
判定ロジックではなく、**その入力となるhistoryを組み立てる`RengasController#build_verse_history`
側の別の不具合**である。症状（句数ngの誤判定）は似るが、原因・所在は異なる。

**実害の定量化（其の四十一で実機再現・検証済み）：**
Run5（72句）の句数ng却下17件のうち、`previous_renga_id`が存在する（verse2以降の）15件を
重複除去したhistoryで再評価した結果、**8件（句数ng却下全体の47%）が誤却下**（重複除去で
違反が消える）と判明した。バグの影響は「連続数の上限（`kukazo_over`、max方向）」にのみ
現れ、verse34の5回連続却下→forced_zatsuエスカレーションは全てこのバグに起因する
（LLMが提案した式目上正しい候補が誤って却下され続けた）。逆に「最低継続数
（`kukazo_under`、min方向）」は、streak表示が実際より1大きく見えるため、本来ngで
あるべき遷移が見逃される（false negative）方向のリスクを構造的に持つ（Run5データでは
verdictが変わる事例は未確認）。

**其の四十一時点で対処しなかった理由（経緯として保持）：** 其の四十一は分析専用の
依頼書であり、`RengasController`本体の変更は禁止範囲だった（D-33-1: 人間承認なしに
変更しない）。そのため修正は専用の依頼書（其の四十二）に切り出して行った。

**次のステップ：** 優先順位（其の四十一 T7で提案・人間合意済み）に従い、次は
next_constraints配線（B-4、`docs/observation_analysis_其の四十一.md` §5）に進む。
着手前に改めてRun5相当の観測を行い、D-41-1修正後の句去ng・句数ng残存分の発生状況を
確認してからB-4に進むことを推奨する（其の四十一 T7参照）。

---

## 其の四十（2026-07-17）追記

---

### D-40-1　OllamaClientにopen_timeoutを明示設定する

**判断：`OllamaClient`の`generate`/`chat`/`chat_with_tools`いずれも`Net::HTTP.new`直後に`http.open_timeout = 5`（秒）を設定する。**

**背景：**
其の三十九run5（`log/observation_sono39_run5_20260716.jsonl`、verse_no=72で沈黙停止）の調査（`docs/investigation_20260717_其の四十冒頭.md`・`docs/investigation_20260717_其の四十続報.md`）で、`OllamaClient`が`read_timeout`のみを明示設定し`open_timeout`には一切触れていないことが判明した。Rubyの`Net::HTTP`は`open_timeout`未設定時デフォルト60秒が適用されるため、Ollamaプロセスが接続確立段階で応答不能な状態に陥った場合でも、1回の呼び出しが60秒間ブロックされうる構造だった。

**理由：**
- OllamaはlocalhostのAPIサーバであり、TCP接続確立は通常ミリ秒単位で完了する。60秒という値はローカル通信の実態に対して過大。
- `RengaGenerator#generate_tsugeku`は内部で最大25回（5×5）のOllama呼び出しループを持つため、接続確立段階の詰まりが1回でも起きるとループ全体が長時間膠着するリスクがある。
- 5秒はローカル接続確立の通常所要時間（ミリ秒単位）に対して十分な余裕を持ちつつ、Ollamaプロセスが応答不能な場合に早期に失敗させられる値として妥当と判断した（10秒・3秒との比較検討の上で選定）。

**結論：** `OllamaClient::OPEN_TIMEOUT = 5`を定数化し、3メソッドすべてで使用する。

---

### D-40-2　HTTPステータスコード検査の追加と、run5インシデントとの関連

**判断：`OllamaClient`の全メソッドで、Ollamaからの応答が2xx以外の場合は明示的に例外化する（`check_status!`private class methodで一元化）。**

**背景：**
run5の調査で、verse73処理中に`OllamaClient.chat`がOllamaからHTTPステータス500を約1秒で受け取っていたことが確定した（`docs/investigation_20260717_其の四十冒頭.md` §1）。しかし従来の`OllamaClient`はステータスコードを一切検査しておらず、JSONボディに`message`/`response`キーが無ければ静かに`nil`を返すだけで、この500応答自体は例外にならなかった。

**理由：**
- ステータスコード無検査のまま`nil`が返ると、呼び出し元（`RengaGenerator`）はOllama側のエラーを「空の付句」として通常のリトライフローに乗せてしまい、実際に何が起きたかがログから追えなくなる。
- run5沈黙停止の直接原因はプロセス終了（続報調査1-2、[[production_run5_complete]]参照）であり、この500応答自体が停止の直接原因ではないと特定されている。ただし、無検査という構造自体は「エラーが発生してもそれと分からない」という別の問題であり、今回のインシデントの有無に関わらず修正すべき不備と判断した。
- `raise "HTTP #{res.code}"`は既存の`rescue => e`（`"Ollama接続エラー: #{e.message}"`）を素通りする形にし、最終的なメッセージが`"Ollama接続エラー: HTTP 500"`のように既存の文体と一貫するようにした。

**結論：** `check_status!`はRuntimeErrorとしてraiseするため、`RengasController`・`script/observe_production_hyakuin.rb`いずれの既存`rescue RuntimeError`フローも変更せずに通る（両呼び出し元のコードは無変更）。

---

### D-40-3　temperatureパラメータ握り潰しバグの混入経緯と教訓

**判断：`OllamaClient#generate`のリクエストボディ組み立てを1箇所（`body`変数）に統一し、`temperature`が実際にリクエストへ反映されるようにする。**

**背景：**
`generate`は`body`というローカル変数に`temperature`をセットしていたが、実際に`req.body`へ送信していたのは別に新規生成したハッシュリテラルであり、`temperature`は一度も反映されていなかった。`git log --follow -p`による全履歴調査（`docs/investigation_20260717_其の四十続報.md` §5）で、このバグは`chat_with_tools`追加・`think:`実装のraw text prepend→JSON APIパラメータ修正と**同一コミット**（`866b63c`, 2026-06-16）で混入したことが判明した。しかもこのコミットのメッセージは`verify_seed_completion.rb`向けの機能（動的ブラックリスト・シード入れ替え）のみを謳っており、`ollama_client.rb`側の変更には一切言及がなかった。

**教訓：**
- 無関係な題名のコミットに他ファイルの変更を紛れ込ませると、レビューの目が向きにくくなり、この種の見落としが混入しやすい。
- 同一diffハンク内で複数の変更（think修正・temperature引数追加）を同時に行うと、片方の変更（bodyハッシュリテラルの書き直し）がもう片方（temperature代入）を無効化する、という相互作用に気づきにくい。
- 機能追加時はコミットを機能単位で分離し、コミットメッセージに変更対象ファイル・変更内容を明記することが、この種のバグの早期発見につながる。

**結論：** バグ自体は`body`変数を`req.body = body.to_json`として一元化することで解消。冗長な二重のハッシュ組み立てもあわせて解消した。

---

### D-40-4　OllamaClient（C層生成関門）への機能追加における運用上の注意

**判断：`OllamaClient`に新しいメソッド・分岐を追加する際は、既存メソッド（`generate`/`chat`/`chat_with_tools`）のrescue粒度・タイムアウト設計をレビューせずそのまま複製しないこと。**

**背景：**
`git log --follow -p`による全履歴調査（`docs/investigation_20260717_其の四十続報.md` §5）で、`OllamaClient`の不備（`open_timeout`未設定・ステータスコード未検査）は最初のコミット（`6c2bbda`, 2026-06-07）から一貫して存在する設計当初からの見落としであり、以降`chat_with_tools`（`866b63c`）・`chat`（`6cf1c8c`、其の三十一 Step C-3）の追加時にも、既存の粗さがレビューされずそのまま複製されていたことが確認された。

`docs/architecture_decisions.md`には`ShikimokuChecker`・`BuiDictionary`等の判定ロジックについてはD-19〜D-38で判断が手厚く記録されている一方、`OllamaClient`（C層の生成関門、全ての付句生成がここを通る）についてはtimeout方針・エラー処理方針に関する設計意図の記述がD-40以前には一切存在せず、コード現物のみが実質的な設計記録になっていた。

**運用上の注意：**
- `OllamaClient`に新しいメソッド・分岐を追加する際は、必ず既存メソッドの`open_timeout`・ステータス検査・rescue粒度を確認し、その時点の設計判断（D-40-1〜D-40-3参照）を踏襲するか、踏襲しない場合はその理由をこのファイルに記録すること。
- 無関係な機能のコミットに`ollama_client.rb`の変更を紛れ込ませないこと（D-40-3の教訓）。
- C層の生成関門という役割上、ここでの見落としは他の全生成経路（`generate_tsugeku`の`generate`/`chat`呼び出し双方）に影響するため、A層（`ShikimokuChecker`）と同等以上に設計意図の記録を残す価値がある。

---

## 其の三十三（2026-07-10）追記

---

### D-33-1　dryrun_hyakuin.rb（検証用）と build_full_prompt（本番）の位置づけ整理

**判断：dryrun_hyakuin.rbはA層（ShikimokuChecker）検証専用ハーネスと割り切る。**

其の三十三でbui自己申告の正規カテゴリ一致率改善（T1測定・T2正規カテゴリ限定・T2改文言簡潔化）に取り組んだが、これは dryrun_hyakuin.rb 内の bui 自己申告というハーネス固有の仕組みに対する最適化であり、本番の生成品質には直接影響しないことを確認した。

**根拠：**

- 本番（`build_full_prompt`）はLLMにbuiを自己申告させていない。
- `tsuki` / `hana` 概念も本番には存在しない（dryrun_hyakuin.rb固有）。
- 両者は同じプロンプト構造からの乖離ではなく、そもそも別アーキテクチャである。

**扱い：** bui一致率改善の成果はハーネス内の記録として残すが、本番プロンプトへの移植は別タスクとして切り離す。移植を検討する際は、本番にbui自己申告・tsuki/hana概念を導入する是非から改めて検討すること。

---

### D-33-2　局面打開の代替アプローチ：詠み手の視点を動かす（記録のみ・未実装）

**位置づけ：今後の打開策の引き出しとして記録する。今回は実装しない。**

mora固着・duplicate_verse固着への機械的救済は現状「季節軸を動かす（雑への転換）」を主な手段としている（`awareness_messages` 内で雑の句への詠み直しを指示する設計、[[project_overview]]参照）。これとは別に、連歌の歌仙技法にある「詠み手を変えることで場面転換する」という発想を局面打開の代替アプローチとして使える可能性がある。

**着想：** 独吟（一人で全句を詠む）という制約上「詠み手を変える」こと自体はできないが、生成時にLLMへ与える視点（誰の心情・立場から詠むか）を意図的に切り替えることで、季を動かさずに語彙・情景の固着を破れる可能性がある。季節軸の転換が使えない場面（雑句が続いている、または季の転換直後で再転換できない等）での補完手段になり得る。

**今回実装しない理由：** 其の三十三は独吟百韻の完成（bui一致率・mora固着対策）を優先しており、視点操作は新規の設計要素を持ち込むため「枯れてから足す」原則に従い保留する。

---

## 其の二十二（2026-06-29）追記

---

### D-22-1　RengaGenerator の ±1音許容設計

**判断：±1音許容（`(mora - target_mora).abs <= 1`）は意図的な設計である。変更しない。**

**根拠：**

- `mora == target_mora` への厳格化は LLM（qwen3:8b）の生成失敗率を上昇させる。5シード×5試行（25回）の試行でも14音に一致しない確率が増し、空文字返却が頻発する。
- `wrong_streak` によるフィードバックループ（温度上昇・シード再選）は許容幅が広いほど機能しやすい。許容範囲を狭めると LLM がより発散し収束しなくなるリスクがある。
- 字余り・字足らずは古典連歌にも存在する技法であり、±1音の句を採用拒否する根拠にならない。
- `KuValidator#validate` の `warning` 返却（15音→「字余りです」）はユーザーへの参考情報として機能しており、自動生成ループの採用判定とは責務が異なる。両者の動作の差異は意図的な設計分離である。

**変更する場合の条件：** 実際に字余り句が連歌品質に悪影響を与えると観測されてから（「枯れてから足す」原則）。

---

### D-22-2　ひらがな表記の神祇語は bui: nil として通過する

**観測日：2026-06-29**

シードプール（3854件）検査で以下の混入を確認：

| surface | yomi | bui |
|:--|:--|:--|
| きみかみ世をは | きみかみよをは | nil |
| 神世の事も | かみよのことも | nil |
| かものやしろの | かものやしろの | nil |

`やしろ`（社）はひらがな表記のため `bui_dictionary.yml` の `社` エントリにヒットせず、`detect_bui` が `nil` を返す。D-21-1 のタイプB（検出漏れ）に該当。

**現状判断：実害なし。対処しない。**

- 現在「神祇」は `forbidden_bui` に指定されるケースがなく、`bui: nil` で通過しても部立制約を違反しない。
- 将来「神祇」を `forbidden_bui` に追加する際は、ひらがな表記語（`やしろ`・`かみよ`・`さかき`・`はらえ`）を `bui_dictionary.yml` に追記する必要がある。

---

## 其の二十一（2026-06-28）追記

---

### D-21-1　bui: nil シードの扱い

**判断：bui: nil は恒久的に通過させる。**

seed pool 実測（3854件）の結果：
- bui あり: 418件（10.8%）
- bui nil:  3436件（89.2%）

nil を除外するとシードが89%減少する。また nil の内訳は：
- タイプA（真の非部立語）：恋・述懐・雑の一般語 → 部立制約に違反しようがない
- タイプB（検出漏れ）：ひらがな表記の植物・水辺語など → detect_bui の辞書拡充問題

人間界（恋・述懐）は文脈依存であり形態素解析では判定不可能。
nil = 「部立なし」の永続的状態として扱い、filter_pool は通過させる。

---

### D-21-2　人間界 bui 辞書の追加方針

**判断：旅・釈教・神祇の3カテゴリのみ追加。恋・述懐は対象外。**

| カテゴリ | 追加語数 | 理由 |
|:--|:--|:--|
| 旅 | 5語 | 固定語彙で誤検出リスク低 |
| 釈教 | 5語 | 仏教専用語で誤検出リスク低 |
| 神祇 | 4語 | 神道専用語で誤検出リスク低 |
| 恋 | 0語 | 「袖」「涙」「思ひ」は他文脈に頻出。文脈依存 |
| 述懐 | 0語 | 純粋に文脈依存。単語では判定不可 |

「神」「法」「寺」「宮」単体は例外規定が多いため意図的に除外。

---

### D-21-3　filter_pool bui フィルタの実装

**判断：filter_pool の先頭で forbidden_bui フィルタを適用する。**

```ruby
if forbidden_bui.any?
  filtered = pool.reject { |s| s[:bui] && forbidden_bui.include?(s[:bui]) }
  pool = filtered.any? ? filtered : pool  # 全滅時フォールバック
end
```

- 既存の季節フィルタ（must_switch / must_continue）は変更なし
- 全滅時はフォールバックして元の pool を使用（生成を止めない）
- コミット: 331f105

---

## 2026-06-26 次句制約システム（其の十七）

### next_constraints の設計

**場所:** `app/services/shikimoku_checker.rb`

**なぜ ShikimokuChecker に置いたか**  
句去・句数のルール（`@rules` / `@kukazo_rules`）を既に保持しているクラスが
制約の計算責任を持つのが自然。RengaGenerator や Controller は「受け取るだけ」にする。

**返却する3キーの根拠**

| キー | 根拠 |
|:---|:---|
| `verse_type` | 長短交互は式目（chotan）で決まる。Controller の KuValidator 判定と二重化するが、式目の根拠はこちらに一本化すべき |
| `forbidden_bui` | 句去ルールから「次句に出すと違反になる部立」を逆算。between < interval - 1 の条件 |
| `season_hint` | kukazo_rules の min/max から継続・転季の義務を判定。LLM に渡すのではなくシード選択に使う |

**意図的にスキープしたもの**
- 植物の cross-interval（花↔木 の異種三句去）: シードに plant_type がなく偽陽性を生む
- 恋の deep count: season_hint には含めない。観測されたら追加
- bui_dict による体用フラグ: compute_forbidden_bui では未使用。事後チェックに任せる

---

### filter_pool の優先順位設計

**場所:** `app/services/renga_generator.rb`

```
1. must_switch（転季義務）→ 現季のシードを除外
2. must_continue（継続義務）→ 現季のシードのみ選択
3. フォールバック → 前句の季語からの推定（従来の挙動）
```

**なぜ従来フォールバックを残したか**  
`previous_renga_id` がない初句（発句への付け）では history が薄く、
ShikimokuChecker の判定が効かない。その場合は前句季語推定が適切。

---

### forbidden_bui が現在未使用な理由

**場所:** `app/services/renga_generator.rb` → `build_seed_pool`

シードの構造に `bui:` フィールドがない。  
```ruby
# 現在
{ surface: "...", yomi: "...", season: "秋", position: "四句" }

# 必要な形（未実装）
{ surface: "...", yomi: "...", season: "秋", bui: ["植物"], position: "四句" }
```

`BuiDictionary` で `surface` を部立判定してタグ付けすれば有効化できる。  
**着手条件:** シード選択で偽陽性（禁止部立を持つシードが選ばれる）が観測されてから。

---

### build_verse_history の verse_type 推定

**場所:** `app/controllers/rengas_controller.rb`

チェーン内の各句の `verse_type` を「現在の前句 maeku_type から逆算」で埋める。
DB に `verse_type` を保存していないため近似的な推定。

```ruby
offset = chain.size - i   # 末尾から何句前か
vtype  = offset.odd? ? maeku_type : (maeku_type == :chouku ? :tanku : :chouku)
```

**将来の改善案:** Renga テーブルに `verse_type` カラムを追加して正確な値を保存する。

---

## 2026-06-26 折末・折立ルール（Phase 8-3）

**場所:** `docs/phase83_design_memo.md`

水無瀬三吟（宗祇・1488）の実データで折境界7箇所を確認した結果、
折跨ぎで恋・述懐・冬・春が平然と継続している事実を確認。  
折跨ぎ制限（折跨ぎの禁）は紹巴以降（1587〜）の現象であり、
水無瀬版には適用されない。

**判断:** 折末・折立ロジックは実装しない。式目バージョンの「器」（ディレクトリ構造）だけ将来のために示す。

---

## 2026-06-26 植物の体用細分化（其の十六）

**場所:** `app/data/kuzari_rules.yml` / `app/services/shikimoku_checker.rb`

```yaml
植物:
  default: 5   # 同種（花↔花 等）
  cross:   3   # 異種（花↔草 等）
```

**根拠:** 水無瀬三吟で kuzari 違反7件のうち植物4件が「花・草・木の異種」で合法と判明。  
残存3件（衣裳・動物・山類）は「枯れてから足す」で保留中。

---

## 2026-06-22 off-by-one 修正（其の十五）

**場所:** `app/services/shikimoku_checker.rb` 77行目

```ruby
# 修正前（誤）
next if between >= interval

# 修正後（正）
next if between >= interval - 1  # 候補句を history に含めないため between は間隔より1少ない
```

**根拠:** `between = n - j`（n=history.size, j=1-indexed直前出現位置）は
句番号の差より常に1少ない。Test1 は偶然相殺されていたため同時修正が必要だった。

---

## 設計の大原則（変えないもの）

| 原則 | 内容 |
|:---|:---|
| 枯れてから足す | 偽陽性・偽陰性が観測されるまで辞書エントリを追加しない |
| 骨法は Ruby、即興はメンタムさん | 式目判定・制約計算は Ruby。付合の詩的飛躍だけ LLM に任せる |
| ShikimokuChecker は純粋関数 | Rails・MeCab・Ollama 非依存。history を受け取り結果を返すだけ |
| 正解データは水無瀬三吟 | 実装の検証は必ず minase_analysis.md / minase_sangin_hyakuin.md と照合する |
| j == n スキップは意図的設計 | 打越チェックと句去チェックの分離。バグではない |

---

## 其の十九（2026-06-28）追記

---

### D-19-1　「短歌一首になるような続き」プロンプトの設計意図

**判断：変更禁止。意図的な設計である。**

前句（17音）＋付句（14音）＝短歌31音 の構造で LLM に自然な接続を促す設計。
「連歌の付け句を作れ」に変えると接続の自然さが損なわれることが確認済み。
将来この行に触れる際は必ず本記録を確認すること。

---

### D-19-2　KIGO_BUI / BUI_EXAMPLE_WORDS 定数の責務分離

**判断：季語フィルタと禁止語説明を定数で分離する。**

- `KIGO_BUI`：季語→部立の対応。kigo_hint 内で forbidden_bui と突合（B層）
- `BUI_EXAMPLE_WORDS`：部立→具体語リスト。build_full_prompt 内で禁止語を展開（C層）

従来は forbidden_bui に部立名をそのまま渡していたが、LLM が概念語を
理解できない場合があった。具体語展開により禁止語の精度が向上した。

---

### D-19-3　kigo_hint の設計方針

**判断：SEASON_WORDS × forbidden_bui の積集合で季語候補を決定する。**

SEASON_WORDS から現季節の語を取得し、KIGO_BUI で forbidden_bui に
含まれる語を除外、前句出現語も除外してランダムに2語をプロンプトへ注入。
雑句の場合は季語注入・情趣ヒントともにスキップする。

---

### D-19-4　Python パッチスクリプト方式の廃止

**判断：其の二十以降は Claude Code を使用する。Python パッチは使わない。**

其の十九で \#\{\} エスケープ問題・インデント誤認・行番号ずれにより
5分の作業が1時間超に及んだ。Claude Code（Mac mini 上で直接実行）に移行する。
*.py パッチスクリプトは .gitignore 対象とし、リポジトリには含めない。

---

### D-19-5　ng「句数不足（春・秋3句以上必要）」の誤判定

**判断：現時点では対処しない。既知問題として記録する。**

RengaChecker が前句・付句の2句だけを見て句数を判定しているため、
孤立した秋2句を「3句ない」と誤判定する。生成品質の問題ではない。
実害が観測されるまで「枯れてから足す」原則に従い保留する。
修正時は ShikimokuChecker#next_constraints の季情報を
RengaChecker プロンプトにも渡す形が最小変更。

---

## 其の三十六（2026-07-15）追記

---

### D-36-1　フェーズ8統合時のbui情報源の限定

**判断：フェーズ8で逆戻り検知の履歴経路にbui情報を含める場合、情報源はB層BuiDictionaryの確定値に限定する。C層（LLM自己申告）のbui値は混入させない。**

**背景：**
其の三十六で新設した逆戻り検知の専用最小経路（案C）は、意図的にtsugeku本文のみを扱い、bui/season/verse_typeを持たせない設計とした（案Cの独立性を保つため）。フェーズ8で`build_verse_history`と統合する際、この経路にbui情報を持たせるかどうかが論点となる。

**理由：**
- `ShikimokuChecker`（A層）はRails/MeCab/Ollama非依存の純粋関数という設計原則を持つ（D-19-5参照）。確定的であるべき判定層に、C層の不確定な自己申告データを持ち込むと、判定結果が「正しい」のか「LLMがそう言い張っただけ」なのか後から区別できなくなる。
- 同一カテゴリの繰り返し回避という用途は、Session 24（其の二十四）で`ichiza_ichiku_words.yml`（B層確定辞書）により既に解決済み。この用途のためだけにC層自己申告を新たに持ち込む必要性は薄い。

**結論：**
bui込みの履歴統合を行う場合、`BuiDictionary`（B層）経由の確定値のみを使用する。C層自己申告（LLMのbui self-report JSONフィールド）はこの経路に混入させない。

**フェーズ8着手時に合わせて確定すべき事項：**
- 経路統合のスコープが「本文取得ロジックの一本化」のみか、「D-19-5解消（句去・句数の全チェーン化）」まで含むかで実装範囲が変わる
- 一座一句物（`ichiza_violations`、3引数形式、Session 24実装）との重複・分散を避ける設計にする

---

## 其の三十八（2026-07-15）追記

---

### D-38-1　RengaCheckerの式目判定役割廃止

**判断：** `RengaChecker`（LLMベース式目チェック）を事後判定から外し、
`ShikimokuChecker`（Ruby決定論的チェック）で置換する。

**理由：**
- RengaCheckerは事後ラベリングに過ぎず、ng判定しても保存を止めない設計だった
- RengaCheckerの「2句だけ見て判定」問題（D-19-5）の根本解消
- 3層アーキテクチャ原則：客観的に検証可能な事実（式目遵守）はRuby側で確定判定する
- メンタムさんの負荷軽減（RengaChecker呼び出し1回分 = 3〜4分のLLM処理が消える）

**影響範囲：**
- `rengas_controller.rb`：RengaChecker呼び出しをShikimokuChecker呼び出しに置換
- `build_verse_history`：bui情報をBuiDictionary確定値で埋める（D-36-1準拠）
- `renga_checker.rb`：ファイルは残すが、controllerからの呼び出しを削除
  （将来、解釈コメント生成等の用途に転用する余地を残す）

**維持するもの：**
- RengaGenerator内部のstreak機構（mora_error_streak/repeat_streak/wrong_streak）は
  一切触れない
- ShikimokuChecker自体のコードは変更しない（A層純粋関数原則維持）
- view（show.html.erb）は`result`/`issues`/`breakdown`の3キーHash互換で無改修

---

### D-38-2　ng時の差し戻し（事後ラベリングから受理/却下へ）

**判断：** ShikimokuCheckerがng（violations非空）を返した場合、Renga.create!を
実行せず、ユーザー（またはメンタムさん）に差し戻す。KuValidatorの字数ng分岐と
同パターン。

**理由：** 決定論的にng判定された句を本データとして保存する理由がない。

**観測方針：** 差し戻し頻度・違反種別をログ（generation_attempts.log相当）に記録し、
自動リトライ（RengaGenerator内でのshikimoku_streak新設）の要否は
実データを観測してから判断する。

---

### D-38-3　文章・文節の分析にはMeCabを標準とする

**判断：** waka-collector内で日本語テキストの語彙分析（モーラ数、部立検出、季語検出、将来の語幹重複フィルタ等）を行う場合は、MeCab（natto gem）による形態素解析を標準手段とする。文字列の部分一致マッチによる代替実装は原則として行わない。

**理由：**
- ひらがな表記（かすみ→霞）の原形正規化にはMeCabが不可欠
- KuValidator（モーラ数）で既にMeCab依存が確立済み
- 連歌の文語体テキストでは活用形・ひらがな表記が頻出し、表層文字列だけでは語彙の同定が信頼できない
- season_from_text（SEASON_WORDSの文字列マッチ）は既存の簡易実装として当面維持するが、将来の精度問題が観測された場合はMeCab版に置き換える候補とする

**例外：** season_from_text等の既存実装で実害が未観測のものは、「枯れてから足す」原則に従い、問題が観測されるまで温存する。

---
