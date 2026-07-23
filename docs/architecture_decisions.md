# waka-collector 設計判断記録

**位置づけ:** 「なぜそう作ったか」を残す生きた仕様書。  
引き継ぎ文書とは別に、設計判断が生まれるたびにここに追記する。  
**更新:** 新しい判断は上に追記する（最新が先頭）。

## 其の五十七（2026-07-23）追記

---

### D-57-1　シード辞書更新の一次資料追加（湯山三吟・遺誡百韻）

**判断：** D-55-1で判明したシード辞書の秋偏重（季節付きシード1,556件中760件＝
48.8%が秋）への対処材料として、宗祇に連なる百韻2件の去嫌一覧を一次資料
（勢田勝郭「新注解」論文、奈良工業高等専門学校研究紀要 第56号・第57号）
から書き起こした。**辞書本体（`BuiDictionary`・`SEASON_WORDS`・`KIGO_BUI`）
への実装反映は今回行わず、観測・リストアップに留める（「枯れてから足す」原則）。**

**成果物：**
- `docs/reference/kiyo_r2_7.pdf`（湯山三吟新注解、研究紀要56号）
- `docs/reference/kiyo_r3_5.pdf`（遺誡百韻新注解、研究紀要57号）
- `docs/reference/yuyama_sangin_kokiraisichiran.csv`（湯山三吟去嫌一覧、100句書き起こし）
- `docs/reference/yuikai_hyakuin_kokiraisichiran.csv`（遺誡百韻去嫌一覧、100句書き起こし）
- `docs/handover_20260723_其の五十七.md`（詳細な書き起こし内容・季節分布比較・辞書突合結果）

**季節分布（一次資料書き起こしによる確定値）：**

| 季 | 水無瀬三吟(1488) | 湯山三吟 | 遺誡百韻(1499) |
|---|---|---|---|
| 春 | 25 | 13 | 19 |
| 夏 | 0 | 4 | 3 |
| 秋 | 22 | 27 | 25 |
| 冬 | 10 | 8 | 6 |
| 雑 | 43 | 48 | 47 |

userMemoryにあった湯山三吟の既存参考値（秋26・春12・夏4・冬9・雑49）は
出典不明のため、本書き起こし値（一次資料直接確認）で置き換える。

**所見（実装は次回以降）：**
- 秋優位の傾向は3作品とも共通（22〜27句）。宗祇独吟の遺誡百韻ですら秋25・春19。
  シード辞書の秋偏重は宗祇周辺の百韻の一般的傾向を反映している可能性がある
- 春句の絶対数は水無瀬三吟(25)が突出しており、秋偏重緩和には湯山三吟・遺誡百韻より
  水無瀬三吟の語彙比重を優先する方が効果的な可能性が高い
- 未登録語彙候補（BuiDictionary・KIGO_BUI両方に未登録）：月・夢・枕・涙・煙・船。
  特に「月」はKIGO_BUIには存在するがBuiDictionary.ymlには存在せず、2辞書間の
  非対称が既にある
- 春季語の補強候補：いとゆふ（糸遊、陽炎の異名）、帰雁（雁は現行SEASON_WORDSで
  秋語のみだが、湯山三吟95句では春句として使用されている＝体用の文脈依存例）

**去嫌一覧表内の記号（×△▽□◎）の意味は原論文内に凡例がなく確定できていない。**
別論文（勢田勝郭「連歌去嫌の総合的再検討」研究紀要52号、未入手）参照とのみ
記載されている。実装検討時は入手を推奨する。

詳細な書き起こし内容・判読困難句一覧・辞書突合の全リストは
`docs/handover_20260723_其の五十七.md`を参照。

---

## 其の五十六（2026-07-23）追記

---

### D-55-1　season_label季固定バグの修正（効果は確認されたが秋偏重の根本解消には至らず）

**判断：** `app/services/renga_generator.rb`のseason_label組み立てロジックを、
`season_hint[:must_switch]`がtrueの場合に限り`seed[:season]`（サンプルされた
シードの季節、なければ"雑"）を使用するよう分岐修正した。修正前は
`season_hint[:current]`（転換元の現在季）がmust_switch判定に関わらず常に
そのままプロンプトへ渡っており、「転季義務が発生しているのに転季元の季節を
指示し続ける」という自己矛盾した状態だった（其の五十四Phase0調査で発見、
当時の行番号でrenga_generator.rb:108）。

**背景：** 其の五十四のPhase0調査（`docs/investigation_20260722_其の五十四_phase0.md`）
で発見されたバグ。其の五十三のsono53_run1（n=98）で「filter_pool経由の季転換は
成功する（85.7%）が、season_hint効果自体は秋52.5%と悪化継続」という一見矛盾した
観測結果が出ていた原因の一つがこれだった可能性がある。

**検証（100句本番run、`observation_batch: sono39_20260722`、詳細は
`docs/handover_20260723_其の五十六.md`）：**
- **修正自体は成功。** must_switch=true発火5回（verse_no 13, 19, 57, 74, 92）の
  すべてで、当該verse自体は転換元季節の回避に成功した（season_from_textでの
  再判定による確認）。修正前はこの検証手段自体が存在しなかった（D-52-1の
  SeasonHintLogログとD-38-3のseason_from_text手法を組み合わせて初めて可能になった）。
- **しかし全体の秋比率は52.5%→53.0%とほぼ横ばい。** 修正の効果は限定的
  だったと評価する。春・夏が0%から出現するようになった（雑への吸収一辺倒
  からの改善）点は副次効果として確認できたが、「句数:秋の削減」という
  D-50-1以来の目標達成には至っていない。

**結論：** バグ修正としては正しく機能しているが、秋偏重問題の根本解消には
別の要因（下記「観測所見」参照）が支配的であり、season_label修正単体では
不十分だった。

**観測所見（未対処・D番号なし）：** 本検証runの分析で、秋偏重の要因として
以下2点が新たに判明した。対処方針は未確定のため、次期依頼書での検討事項
として記録するに留める。

1. **シード辞書内の季節付きシードが秋に偏っている。** `build_seed_pool`が
   返す全体プール（3,854件）のうち季節ラベル付きの1,556件（季節未設定
   2,298件を除く）だけで見ると、秋は760件＝48.8%を占める。季節付きシード
   の約半数が秋であり、maeku_season依存のデフォルトフィルタが働くたびに
   秋が選ばれやすい構造になっている。
2. **must_switch発火時、秋除外後の残りプールも74.3%が「雑」。**
   `filter_pool`のmust_switch分岐（`pool.reject{season==current}`）で
   秋760件を除外しても、残り3,094件のうち2,298件（74.3%）は季節未設定
   （雑）であり、season_labelが実質「雑」（無指定）になりやすい。季節
   誘導力が弱いまま生成が進むため、除外直後の1〜2句で季節統制が緩み、
   デフォルトフィルタ経由で秋に引き戻されやすいと推測される。

シード辞書の季節ラベル偏り是正、フォールバック先変更（「雑」以外の具体季節
へのランダムフォールバックなど）は、**「枯れてから足す」原則に従い今回は
実装しない。** 次回の依頼書で改めて対処方針を検討する。

---

## 其の五十二（2026-07-21）追記

---

### D-52-1　SeasonHintLoggerによるmust_switch/must_continue発火ログの可視化

**判断：** `ShikimokuChecker#compute_season_hint`が返す`must_switch`（季節上限到達→転季義務）/`must_continue`（季節下限未達→継続義務）の発火状況を、`app/controllers/concerns/season_hint_logger.rb`に新設した共通モジュール`SeasonHintLogger`経由で`Rails.logger.info`に出力するようにした。フォーマット：`[SeasonHint] verse_no=XX season=秋 count=5 must_switch=true must_continue=false`。季雑（`season_hint[:current]`がnil）の場合はログをスキップする。

**背景：** 其の五十一の申し送り事項2（`docs/handover_20260720_其の五十一.md`）で指摘されていた「must_switch/must_continueの発火有無を確認するログが存在しない」というブラックボックスの解消。D-51-1（RengaGenerator内部却下ログ）とは異なり毎リトライで出力されるものではなく、1 verseにつき最大1行のため、**恒久的にログとして残す方針**とした（revert前提のD-51-1とは性質が異なる）。

**ログ追加箇所の設計（候補A/B/C/D比較）：** Phase 0調査の結果、`next_constraints`の消費箇所は`RengasController#create`（Web版）と`script/observe_production_hyakuin.rb`（観測版）の2箇所のみと判明。
- 候補A（`compute_season_hint`内部）：`ShikimokuChecker`のA層純粋関数設計（D-38-1）を壊すため却下。
- 候補C（観測スクリプトのみ）：Web版の発火状況が見えないままになり、観測系とWeb版の一致という要件を満たさないため却下。
- 候補B（2箇所に同一ログコードを直接複製）を最初に提示したが、人間の判断で**候補D（共通concernモジュール化）**を採用。`RengasController`は`include SeasonHintLogger`し、`observe_production_hyakuin.rb`は既存の`controller.send(:build_verse_history, ...)`と同じ流儀で`controller.send(:log_season_hint, next_constraints, verse_no: verse_no)`として呼び出す。ログ処理の実装は1箇所に集約され、フォーマット乖離のリスクを候補Bより低減できる。

**D-33-1抵触の有無：** 抵触あり（`RengasController`・`observe_production_hyakuin.rb`双方への変更）。diff事前提示・承認を経て実装。`ShikimokuChecker`・`RengaGenerator`本体のロジックは無変更（`verify_shikimoku.rb` 88 pass/0 fail維持）。

**動作確認（15句短縮run、タグ=sono52check、2026-07-21）：**
- `must_continue=true`：verse_no 2,3,5,6,10,11,14,15の計8回出現。季節開始直後（count=1〜2）に一貫して発火し、count=3（min到達）で`false`に転じることを確認。
- verse_noと実句番号（stdout「N/15句目」表示）の対応：ズレなし。
- 季雑スキップ：verse_no 1（発句）・13（季語なし句「夜空に星の光りゆかしや」）の2箇所でログが出力されないことを確認（設計通り）。
- `must_switch=true`：verse_no=9（春count=5、max到達）で出現。想定では「短縮runでは恐らく未出現」だったが、偶然15句以内で到達し確認できた。ただし直後の9句目は式目ngが解消せずforced_zatsuへエスカレーションしており、`RengaGenerator#filter_pool`内の`must_switch`分岐（同季拒否→フィルタ）が意図通り機能して季転換に成功したケースは本runでは未確認（forced_zatsu救済経路での転換のみ観測）。**「must_switch発火時にfilter_pool経由で季転換が成功するか」は其の五十三以降の課題として残す。**

**次点の課題：**
1. 上記「must_switch発火時のfilter_pool経由季転換」の100句run規模での確認
2. D-50-1のseason_hint効果（句数:秋の改善）自体は本ログでは検証できないため、既存の申し送り事項（其の五十一 D-50-1参照）は引き続き未解消

---

## 其の五十一（2026-07-20）追記

---

### D-51-1　RengaGenerator内部却下理由の診断ログ（一時追加→revert）

**判断：** `app/services/renga_generator.rb`の`generate_tsugeku`内部ループ（5シード×5試行）の却下分岐2箇所（モーラ不一致／echo・鸚鵡返し・固着・history_repeat）に`Rails.logger.info`を1行ずつ追加し、`category=model`（モデル出力自体の問題：モーラ不一致・echo・鸚鵡返し）と`category=prompt`（候補プール・制約側の収束が疑われるもの：固着・history_repeat）に分類してログした。sono51_run2（100句、D-50-1検証run）で実戦投入し、内部却下948件中901件がcategory=model（95%）、47件がcategory=prompt（5%）という内訳を確認した後、**本番development.logの常時ノイズになるため人間の判断でrevertした**（コミットハッシュは末尾参照）。

**背景：** sono51_run1（其の五十、D-50-1検証の100句run、95句で中断）で「生成失敗」（`RengaGenerator`が空文字を返す＝内部25回全滅）が40件観測され、原因がモデル側要因（モーラ不一致）かプロンプト側要因（duplicate等）か切り分けたいという要望から着手した。既存コードには却下理由をログする箇所が一切なく、`observe_production_hyakuin.rb`側のjsonlログも外側の試行結果（create/retry/exhausted等）のみで、`RengaGenerator`内部の25回ループの中身は不可視だった。

**KuValidatorの独立モーラ判定との違い（要記録）：** 本診断が捕捉するのは`RengaGenerator`内部の候補却下（`morphemes_of`独自実装、±1音許容、D-22-1）のみ。`observe_production_hyakuin.rb`側が`generate_tsugeku`の戻り値に対して行う`KuValidator#count_mora`（`yomi_string.gsub(/[ゃゅょ]/,'').length`という別実装）による再チェックは対象外（jsonlに`violations:["モーラng(##音)"]`として既に独立ラベル済みのため、追加計装不要と判断）。この2つのモーラ計算は独立実装であり、`RengaGenerator`が内部で許容した候補が`KuValidator`側で改めてngになるケースが理論上あり得る（別経路・別問題として扱うこと）。

**D-33-1抵触の有無：** 抵触あり。`RengaGenerator`本体（本番`RengasController`からも呼ばれる）への変更のため、実装前にdiffを人間に提示し承認を得てから実装した。`verify_shikimoku.rb`は88 pass/0 fail維持（ログ追加のみでロジック分岐は無変更）。

**再導入の要否：** must_switch/must_continue（season_hintのフラグ）の実発火有無は現状ログから一切確認できない（別途要計装、次の課題として残す）。次回この種の内部診断が必要になった際は、revertコミットを`git revert`で取り消せば再導入できる。

**コミット履歴：** 追加コミット `14bcf5c481c2ee3b8ca044ce915996b1e1b9dadd`、revertコミット `09bb0037ddc489b832fcdcdcfd34ba7ee0e37da0`。再導入する場合は`git revert 09bb0037ddc489b832fcdcdcfd34ba7ee0e37da0`（＝revertのrevert）でD-51-1のログ2行を復元できる。

---

## 其の五十（実施時期不明、2026-07-20時点で事後記録・本番稼働判定）追記

---

### D-50-1　observe_production_hyakuin.rbへのnext_constraints配線

**判断：** `script/observe_production_hyakuin.rb`で、`RengasController#create`（D-44-1）と同じく`history`/`checker`の構築を`RengaGenerator.new`呼び出し**前**に繰り上げ、`next_constraints = checker.next_constraints(history)`を算出して`constraints: { verse_history:, forbidden_bui:, season_hint: }`として渡すよう配線した。D-44-1の時点では「観測スクリプトへの配線は今回は対象外」として見送られていたものを、本セッションで着手した。

**経緯の特記事項：** この変更は本conversationの開始時点で既に作業ツリーに存在しており（コミットなし、`docs/architecture_decisions.md`への記載もなし）、いつ・どのセッションで実装されたか正確な記録がない。其の四十九というセッション番号もgit履歴上存在しない（欠番、または口頭作業のみで記録が残らなかったと推定）。本記録は事後的に其の五十として追記するものである。

**本番稼働判定（2026-07-20、sono51_run1・sono51_run2の観測により実施）：**

| 指標 | 其の四十五 Run1〜4（配線前） | sono51_run1（D-50-1、95句中断） | sono51_run2（D-50-1、100句完走） |
|---|---|---|---|
| ng率 | 31.7%〜40.2% | 42.9%（範囲外・n不完全） | 36.1%（範囲内） |
| 句数:秋 発生率 | 12.8%〜19.5% | 16.1%（範囲内） | 23.2%（範囲外・最高値） |
| action:error | - | 0件 | 0件 |
| forced_zatsu | - | 1句 | 4イベント（3, 51, 98, 100） |

sono51_run1は途中でtmuxサーバーごとプロセスが外部終了した（Ollama側の異常ではなく、クライアント接続が処理中に切断されたことを示す`ollama.log`の500応答[105ms、直前まで正常応答]と、development.logに例外ログが一切残っていないことから外部kill説を採用。詳細は本セッションの調査ログ参照）。sono51_run2で完走を確認し、総合ng率はベースライン範囲内、クラッシュ系は健全である一方、season_hintが直接改善を狙う「句数:秋」はn=2で16.1%→23.2%と悪化方向に振れており、季節遷移の狙い通りの効果が出ているとは言い切れない。

**人間の最終判断（2026-07-20）：** 上記を踏まえた上で「D-50-1は本番稼働に問題なし」と判断（Nobuson）。ただしseason_hintの効果自体（句数:秋の改善）は未実証のまま運用開始することになる点は申し送り事項とする。次点の課題：①must_switch/must_continueの発火ログ追加、②もう1本100句runでの句数:秋の再現性確認。

**D-33-1抵触の有無：** 抵触あり（`script/observe_production_hyakuin.rb`単体だが`RengaGenerator`呼び出しの`constraints`引数を変更するため）。ただし人間承認プロセスを経ずに作業ツリーへ導入された経緯があり、本記録時点で遡って承認・sign-offを得た形になる。

---

## 其の四十八（2026-07-19）追記

---

### D-48-1　run_observe_and_summarize.sh新設（100句run自動化＋結果サマリー）

**判断：** `script/run_observe_production.sh`（D-46-1）と同じく`observe_production_hyakuin.rb`
本体は無変更のまま、新規スクリプト`script/run_observe_and_summarize.sh`を追加した。
`bundle exec rails runner script/observe_production_hyakuin.rb <verses> <tag> 2>&1 | tee
<stderr_log>`でstderrキャプチャを維持しつつ、実行後にjsonlログ・stderrログを
自動集計してサマリーファイル`log/observation_<tag>_summary.txt`に書き出す。
`set -e`は使わない（rails runnerが非0で終了してもサマリー書き出しを必ず実行するため。
クラッシュ時こそサマリーが必要という設計意図）。

**引数順序がrun_observe_production.shと異なる理由：** `run_observe_production.sh`は
`<verses> <tag>`の順だが、本スクリプトは`<tag> [verses=100]`の順（tagが必須第一引数、
verses省略時100）。其の四十八の依頼書で人間が`script/run_observe_and_summarize.sh
sono48_run1`という1引数呼び出しを明示していたため、それに合わせた。両スクリプトの
引数順が不揃いになる点は認識した上で、依頼書の指定を優先した。

**集計ロジック：** 総試行回数・総ng回数・forced_zatsu採用数は、`observe_production_hyakuin.rb`
本体の内部カウンタ（`total_attempts`/`total_ng`/`forced_zatsu_creates`/
`forced_zatsu_mora_ng_ct`）と同じ判定基準をjsonlログの`action`フィールドから
再現している（`action`が`retry`/`exhausted`/`forced_zatsu`/`forced_zatsu_mora_ng`/
`forced_zatsu_create`/`create`のいずれかを対象、`seed`/`maeku_ng_continue`/`error`は
除外）。この方式は正常完走時だけでなくクラッシュ時（スクリプト本体が最終サマリーを
`puts`する前に終了する場合）でも同じ精度で集計できる利点がある（stdout文字列の
grep依存だと正常完走時しか機能しないため採用しなかった）。

**完走判定：** 依頼書の指定通り「verse_no:目標句数の行が存在するか」をjq
（`any(.[]; .verse_no == $v)`）で判定。加えて`rails runner`の終了コードも
あわせて見て「完走」「到達したが異常終了」「未完走」の3状態を区別する。

**クラッシュ時のstage抽出：** D-47-1（其の四十七）がstderrに出力する
`[observe_production_hyakuin] verse_no=... stage=...`行をgrepで抽出。jsonlの
`action: "error"`エントリも件数・内容とも表示する。D-47-1のstage記録が
このスクリプトの診断機能の前提になっている。

**D-33-1抵触の有無：** 抵触なし。新規スクリプトであり、`observe_production_hyakuin.rb`・
`RengasController`・`RengaGenerator`・`ShikimokuChecker`本体はいずれも無変更。
D-46-1と同じ理由でこの新規スクリプトには人間承認ゲートを踏まず実装した
（依頼書内で判断を委任されていた）。

**動作確認：** 成功パス（3句スモーク、`sono48smoke_ok`タグ）でサマリーの
総試行回数6・総ng回数3・ng率50.0%が観測スクリプト自身の`puts`出力と一致することを
確認。クラッシュパスは`config/initializers/`に一時ファイルを置き
`BuiDictionary#detect_all`をRailsブート時にモンキーパッチしてテスト後即削除する形で
検証（3句、`sono48smoke_crash`タグ）。`stage=bui_dict/season_from_text`の抽出、
`action: "error"`1件の検出、終了コード1の伝播、いずれも正しく機能することを確認した。
検証用Renga（`sono39_sono48smoke_ok_20260719`、3件）・jsonl/stderrログ・サマリー
ファイルは人間確認の上削除済み。`verify_shikimoku.rb`は88 pass/0 fail維持
（本体3ファイル無変更のため影響なし）。

**残課題（クローズ）：** 本番相当の100句run（`script/run_observe_and_summarize.sh
sono48_run1`）は人間（Nobuson）がtmuxから起動し、2026-07-19に実行完了した。
結果：完走（verse_no:100到達、終了コード0）、総試行154・総ng54・ng率35.1%
（其の四十五Run1〜4のレンジ31.7%〜40.2%内）、`action: "error"`0件、
クラッシュ0件。本スクリプトの集計ロジック（jsonlの`action`フィールド再集計）
・完走判定（jq）・stage抽出（grep）のいずれも正常系で問題なく機能した
（クラッシュ系の実戦検証はスモークテストのみで、今回のrunでは未発火）。
D-47-1の残課題（run5相当の無言クラッシュ再発有無の確認）も本runで
解消と判断し、D-47-1側に追記した。以上により其の四十八の残課題はクローズする。

---

## 其の四十七（2026-07-19）追記

---

### D-47-1　observe_production_hyakuin.rbの無防備な例外経路にrescue追加（案A）

**判断：** `script/observe_production_hyakuin.rb`の`(1..TOTAL_VERSES).each do |verse_no|
... end`ブロックに、Ruby 2.6+のブロックレベルrescue構文で`rescue StandardError => e`
を直接付けた（既存行の再インデント不要、最小diff）。あわせて`stage`変数を
KuValidator（前句／付句）・bui_dict/season_from_text・build_verse_history・
ShikimokuChecker・forced_zatsu_candidates・Renga.create!の各呼び出し直前で更新し、
rescue時にverse_noとstageの両方をログできるようにした。rescue内では
`warn`（標準エラー出力、D-46-1の`run_observe_production.sh`の`2>&1 | tee`で
ファイル保存される）と`log_line`（既存jsonl、`action: "error"`）の両方に記録した上で
`raise`により再送出する（握りつぶさない。プロセスは従来通り停止する）。

**背景：** 其の四十バックログ①・其の四十七 Phase 0調査
（`docs/investigation_20260718_其の四十七_phase0.md`）。既存の3rescue箇所
（`RuntimeError`/`Net::ReadTimeout`限定×2、`RetryExhausted`限定×1）の対象外だった
KuValidator検証・bui_dict検出・build_verse_history・ShikimokuChecker各種チェック・
`Renga.create!`呼び出しは無防備で、ここで発生した`StandardError`系例外
（`NoMethodError`・`ArgumentError`・`ActiveRecord::RecordInvalid`等）はどこにも
捕捉されずトップレベルまで伝播し、原因不明のまま無言終了していた
（run5で実際に発生した障害と同種）。

**案Bを不採用とした理由：** `rescue Exception`まで広げて`NoMemoryError`等も
含めて捕捉する案は検討したが不採用。`NoMemoryError`・`SystemStackError`はRuby VM
自体が異常状態にある可能性が高く、この状態で追加のログ書き込み処理を行うこと
自体が二次障害を招くリスクがある。また`Exception`を広く捕捉すると`SystemExit`・
`Interrupt`（Ctrl-C）まで飲み込んでしまう副作用もある。これらは捕捉して復旧を
試みるべき対象ではなく、むしろ潔く落ちるべき例外と判断した。

**D-33-1抵触の有無：** 抵触なし。変更は`script/observe_production_hyakuin.rb`
単体に閉じており、`RengasController`・`RengaGenerator`・`ShikimokuChecker`本体は
無改修。

**動作確認：**
- `bundle exec ruby script/verify_shikimoku.rb`は88 pass/0 fail維持（本体3ファイル
  無変更のため影響なし）。
- 5句のスモークテスト（`bundle exec rails runner script/observe_production_hyakuin.rb
  5 sono47smoke`）で全句正常にcreateされ、新設rescueは発火しないことを確認
  （検証用Renga 5件[observation_batch: "sono39_sono47smoke_20260719"]は人間確認の上削除済み）。
- 意図的な例外発生テスト：`BuiDictionary#detect_all`をモンキーパッチで
  `RuntimeError`を投げるよう差し替え、`rails runner`経由で実行。stderrに
  `stage=bui_dict/season_from_text`付きのログが出力され、jsonlログにも
  `action: "error"`エントリ（`violations`に`stage`と例外クラス・メッセージ）が
  記録された上でプロセスが終了コード1でクラッシュすることを確認した
  （テストスクリプトはリポジトリ外の一時ファイルで実施、本体は無改変）。

**残課題：** 其の四十で挙げたバックログ①②（`docs/handover_20260717_其の四十.md`
§4）は、②が其の四十六（D-46-1）、①が本セッション（D-47-1）で両方対応完了。
次はstderrキャプチャ＋rescue範囲見直しの両方が揃った状態で改めて本番相当の
観測run（100句）を実行し、run5のような無言クラッシュが再発しないか、
再発した場合は原因がログから復元できるかを確認することを推奨する。

**追記（其の四十八、2026-07-19）：実戦検証結果。** 上記の残課題を
`script/run_observe_and_summarize.sh sono48_run1`（D-48-1、100句）で実施した。
結果は完走（verse_no:100到達、`rails runner`終了コード0）、D-47-1由来の
`action: "error"`エントリは0件（＝本rescueは今回発火せず、run5のような
無言クラッシュは再発しなかった）。ng率35.1%（総試行154・総ng54）は
其の四十五Run1〜4のレンジ（31.7%〜40.2%）内に収まっており、rescue追加による
挙動面での副作用（不要なリトライ増加等）も見られない。D-47-1が備えていた
「クラッシュ時にstage/verse_noをログから復元できる」機能自体は今回未発火のため
実戦での発動は未検証のままだが、run5相当の障害が起きないこと自体は
本runで裏付けられた。詳細は`log/observation_sono48_run1_summary.txt`
（人間確認後、要否に応じて別途保存判断）を参照。

---

## 其の四十六（2026-07-18）追記

---

### D-46-1　observe_production_hyakuin.rb起動時のstderrキャプチャ追加

**判断：** `script/observe_production_hyakuin.rb`本体は無変更のまま、起動用の
薄いラッパー`script/run_observe_production.sh`を新設した。`bundle exec rails
runner script/observe_production_hyakuin.rb <verses> <tag>`を`2>&1 | tee
log/observation_stderr_<tag_>_<date>.log`で包み、Rubyの未捕捉例外バックトレース
を確実にファイル保存する。

**背景：** 其の四十のバックログ②（`docs/handover_20260717_其の四十.md` §4）。
run5でプロセスが無言終了した際、tmuxスクロールバックが空でstderr保存設定も
なかったため、どの例外が投げられたか復元不可能だった。

**なぜラッパースクリプトか（本体を直接変更しなかった理由）：** stderrキャプチャは
「起動方法」の問題であり、Rubyスクリプト自身が自分の標準エラー出力を
リダイレクトすることはできない（シェル側の責務）。`observe_production_hyakuin.rb`
本体・`RengasController`・`RengaGenerator`・`ShikimokuChecker`は無改修。

**動作確認：** 5句のスモークテスト（`script/run_observe_production.sh 5
sono46smoke`）で、`log/observation_stderr_sono46smoke_20260718.log`が生成され
stdout/stderr両方が記録されることを確認した（bundlerのGem::Platform警告＋通常の
進捗出力が両方ファイルに残っている）。検証用に作成されたRenga 5件
（observation_batch: "sono39_sono46smoke_20260718"）は人間確認の上削除予定。
`bundle exec ruby script/verify_shikimoku.rb`は88 pass/0 fail維持（本体無変更のため
影響なし）。

**残課題：** バックログ①（rescue範囲見直し）は今回未着手。`rescue RuntimeError,
Net::ReadTimeout`のみを捕捉する現状の構造上の欠陥（`NoMemoryError`等や
`RengaGenerator`内部の非RuntimeError系`StandardError`がすり抜ける問題）は
次回セッションで着手する。

---

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
