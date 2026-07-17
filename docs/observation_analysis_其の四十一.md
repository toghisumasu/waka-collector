# waka-collector 其の四十一 分析報告（Run5ログ分析とB-3/B-4判断）

作業日: 2026-07-17
対象: `log/observation_sono39_run5_20260716.jsonl`（其の三十九run5、72句到達で停止）
性質: **分析・調査のみ。`RengasController`/`RengaGenerator`/`ShikimokuChecker`本体・DBは無変更。**
ゲートチェック: `verify_shikimoku.rb` 88 pass / 0 fail（作業前後とも確認、未変更）

## 0. 対象ログについての訂正（人間確認済み）

依頼書は「其の三十九Run2」（`log/observation_sono39_run2_20260716.jsonl`）を分析対象として
指定していたが、該当ファイル・tmuxセッション・DBの`observation_batch`のいずれにも
"run2"に対応するものが存在しないことが判明した。人間に確認の上、**このプロジェクトで
最も進捗の大きい観測ログである`sono39_run5_20260716`（72句）を分析対象とする**ことで
合意した。其の四十の調査（クラッシュ仮説の検証）とは目的が異なる（ng却下頻度・違反種別の
分布集計）ため、同じログの再分析であっても重複ではない。

## 1. T1: Run5の完走確認

- tmuxセッション`sono39_observe_run5`は存在するが、ペインは空のシェルプロンプトのみ
  （其の四十調査時と同状態、変化なし）
- 対応するrubyプロセスは存在しない（`ps aux`で未検出）
- DB（`observation_batch: "sono39_run5_20260716"`）: 72件、id=307〜378
- jsonl: 117行（seed 1 + attempt 116）、最終verse_no=72
- **100句には未到達。72句で停止したまま（完走ではない）。** 停止原因（Rubyプロセス
  クラッシュ）は其の四十で調査済み（`docs/handover_20260717_其の四十.md`参照）

## 2. T2: ng却下頻度の集計

集計スクリプト: `script/analyze_sono41.rb`（新規、読み取り専用）

```
$ ruby script/analyze_sono41.rb log/observation_sono39_run5_20260716.jsonl
```

| 指標 | 値 |
|---|---|
| 総attempt数（seed除く） | 116 |
| 主ループ試行数（forced_zatsu系除く） | 109（create 69 + retry/exhausted 40） |
| 主ループng却下率 | 40/109 = **36.7%** |
| forced_zatsuエスカレーション発動verse | 3/72句 = 4.2%（verse 34・52・67） |

## 3. T3: 違反種別の分布集計（字数ngと式目ngを分離）

### 3-1. attempt行の排他的分類

| 分類 | 件数 | 割合 |
|---|---|---|
| create（成功） | 69 | 59.5% |
| shikimoku_ng（式目違反） | 21 | 18.1% |
| generate_fail（生成失敗＝空応答） | 19 | 16.4% |
| forced_zatsu_progress（レスキュー中間試行） | 5 | 4.3% |
| forced_zatsu_mora_ng（レスキュー安全弁） | 2 | 1.7% |

### 3-2. 字数ng（モーラng）は主ループでは0件

**重要な発見：** 観測スクリプトレベルでの`モーラng`（`KuValidator`が字数超過・不足と判定）は
主ループでは**0件**だった。字数の調整自体は`RengaGenerator#generate_tsugeku`内部の
5×5ループ（其の三十一Step C-3のSocratic対話含む）で既に吸収されており、外側の
観測スクリプトに戻ってくる時点では「字数が合わない句」ではなく「一句も得られない
（空応答＝生成失敗）」という形で現れる。generate_fail(19件)のうち相当数はこの
内部ループの字数調整が最後まで収束しなかったケースと推測される（jsonlに内部ループの
試行詳細は残らないため、正確な内訳は未確認事項）。

**したがって「字数ngと式目ngを混同しない」という測定規律（依頼書T3）を踏まえると、
Run5で観測された式目レベルのng却下は実質的にすべて式目違反（ShikimokuChecker）由来であり、
字数由来ではない。**

### 3-3. 式目ng（21件）の内訳

| カテゴリ | 件数 |
|---|---|
| 句数（kukazo、季節・部立の連続数規制） | 17 |
| 句去（kuzari、同一部立の再出規制） | 4 |

## 4. T4: D-19-5関連の実害確認【重要な新発見】

### 4-1. 前提の整理

D-19-5は元々「RengaChecker（LLMベース）が前句・付句の2句だけを見て句数を誤判定する」
という問題として記録された（`docs/architecture_decisions.md` D-19-5）。其の三十八
（D-38-1）でRengaCheckerはShikimokuCheckerに置換されており、**ShikimokuCheckerの
`kukazo_violations`は`history`（複数句の配列）を受け取り、`current_season_streak`で
末尾から遡ってstreakを数える設計になっている。2句だけしか見ないという原literal な
制約はコード上もはや存在しない。**

`RengasController#build_verse_history`は`fetch_verse_chain(previous_renga_id, limit: 9)`
で直近9句分の履歴を取得しており、句数規制の最大値（春・秋・恋=5句、他=3句）に対して
十分な窓幅を持つ。

### 4-2. しかし、履歴構築に別の実害あるバグを発見した

`RengasController#build_verse_history`（119〜156行目）を精査したところ、
**直前の1句（maeku）が履歴に二重カウントされるバグ**を発見した。

```ruby
def build_verse_history(previous_renga_id, maeku, maeku_type, nm: build_mecab, bui_dict: BuiDictionary.new)
  chain = fetch_verse_chain(previous_renga_id, limit: 9)   # ← previous_renga_id自体を含む
  history = chain.each_with_index.map { |r, i| ... }
  history << { bui: ..., season: season_from_text(maeku), verse_type: maeku_type }  # ← maeku を再度追加
  history
end
```

`fetch_verse_chain(previous_renga_id, ...)`のSQLは`WHERE id = ?`（`previous_renga_id`自体）
を起点とする再帰CTEであり、返る配列の末尾（`ORDER BY depth DESC`＝depth0が最後）は
**`previous_renga_id`が指す句そのもの＝`maeku`と同一の句**である。その直後に
`history << {... season_from_text(maeku) ...}`で同じ句をもう一度追加しているため、
**直前の1句が常にhistory内で2回連続してカウントされる。**

#### 実機再現（verse34の例、其の四十一で実施）

```
verse33（maeku, "秋"）を末尾に持つhistoryの秋streak（候補を含まない）: 5
  → 本来の正しいstreak: 4（verse30〜33の4句連続。重複バグにより+1され5になっている）

verse34 attempt1の候補「秋風のささやきに心ゆかし」（季節:秋）を評価:
  バグ入りhistory: kukazo_violations → [streak:6, max:5] でng却下
  重複を手動除去したhistory: kukazo_violations → [] （ng無し、本来は受理されるべき）
```

verse34の5回の却下・forced_zatsuエスカレーションはすべてこのバグが原因で、
**LLMが提案していた「秋の情趣を保った続き」は式目上正しい候補だったにもかかわらず、
バグにより誤って却下され続けていた。**

#### 全17件の句数ng却下への影響を定量化

`previous_renga_id`が存在する（verse2以降の）句数ng却下15件について、重複を除去した
historyで再評価した結果：

| 判定 | 件数 |
|---|---|
| バグにより誤却下（重複除去で違反が消える＝kukazo_over系） | **8件**（verse30×2, verse34×5, verse56×1） |
| 重複除去後も同じ判定（kukazo_under系、streak表示が1ずれるだけで結論は不変） | 7件 |
| 対象外（verse1、previous_renga_idなし＝バグの影響を受けない・正当なng） | 3件 |

**式目ng却下21件のうち8件（38%）、句数ng却下17件のうち8件（47%）が、この履歴構築バグに
起因する誤却下だった。** バグの性質上、影響は「連続数の上限（max）方向」にのみ現れる
（`kukazo_over`が本来より1句早く発動する）。逆に「最低継続数（min）」方向
（`kukazo_under`、春・秋のみ）は、重複によりstreakが実際より1大きく見えるため、
**本来ngであるべき遷移が誤って見逃される（false negative）方向に働く可能性がある**
（今回のRun5データでは verdict が変わる事例は確認されなかったが、構造的なリスクとして
記録する）。

### 4-3. 結論

- 依頼書が前提とした「D-19-5＝隣接ペアのみ判定」という原初の問題は、ShikimokuChecker
  自体には**存在しない**（D-38-1で解消済み）
- しかし、**ShikimokuCheckerに渡す履歴を組み立てる`RengasController#build_verse_history`
  に、直前1句を二重カウントする別のバグがあり、これが句数ng却下の半数近くを占める
  実害を生んでいる**。これは「B-3（D-19-5対応）」という名前で想定されていた問題とは
  異なる場所・異なるメカニズムのバグだが、同じ「句数判定が実データに基づき誤る」という
  症状のカテゴリに属する
- このバグは`RengasController`本体に存在し、今回の依頼書の禁止範囲（本体変更禁止）に
  該当するため、**今回は修正しない**（T4は実害確認のみ）

## 5. T5: next_constraints配線状況の調査（読み取り専用）

`ShikimokuChecker#next_constraints(history, bui_dict: nil)`（393〜413行目付近）は
`{ verse_type:, forbidden_bui:, season_hint: }`を返すメソッドとして実装・テスト済み
（`script/verify_shikimoku.rb`試験9で検証されている）。

`RengaGenerator`内部（`filter_pool`・`kigo_hint`・`build_full_prompt`）は
`@constraints[:forbidden_bui]`を正しく参照する実装になっている：

- `build_full_prompt`: forbidden_buiが非空なら「禁：〈語〉の語は避けること」を
  プロンプトに挿入
- `kigo_hint`: forbidden_buiに該当する季語候補を除外してから選ぶ
- `filter_pool`: forbidden_buiに該当するseedを候補プールから除外

**しかし、`next_constraints`を実際に呼び出し、その結果を`RengaGenerator.new`の
`constraints:`引数に渡している箇所は、生成パス全体を通じて`script/dryrun_hyakuin.rb`
（検証用ハーネス、370行目）**のみ**であることを確認した。**

- `app/controllers/rengas_controller.rb#create`: `constraints: { verse_history: ... }`
  のみ渡しており、`forbidden_bui`・`season_hint`は一切渡していない
- `script/observe_production_hyakuin.rb`: 同様に`constraints: { verse_history: ... }`
  のみ

したがって、**本番・其の三十九観測スクリプトの両方で、`RengaGenerator`は
`forbidden_bui`を常に空配列として扱っている**（`@constraints[:forbidden_bui] || []`が
常に`[]`にフォールバックする）。`season_label`も`season_hint`経由ではなく、
`maeku_season`（前句テキストからのローカル推定）にフォールバックしている。

D-33-1（`docs/architecture_decisions.md`）は「dryrun_hyakuin.rbはA層検証専用ハーネスと
割り切る」という判断を既に記録しているが、これは"bui自己申告一致率"の文脈での判断であり、
next_constraints/forbidden_bui配線については別途の判断・記録が見当たらなかった。

## 6. B-3 / B-4 優先順位の判断材料（T4・T5の統合）

| 項目 | 実害の有無・規模 | 修正の複雑さ（推測） |
|---|---|---|
| B-3相当（履歴構築の二重カウントバグ、`build_verse_history`） | **実害あり・定量化済み**：句数ng却下の47%（8/17件）が誤却下。verse34のforced_zatsuエスカレーション（5回却下）は全てこのバグ由来 | 局所的：`fetch_verse_chain`の返り値と`maeku`引数が同一句を指す場合の重複除去のみ。修正箇所はおそらく`build_verse_history`内の数行 |
| B-4（next_constraints配線） | **配線が存在しない**ため、LLMは句数・部立の禁止情報を一切事前に与えられず、生成→事後棄却の往復に依存している。ただし今回のRun5データでは、却下の主因（句数ng却下8/17件）は「配線がないから」ではなく「二重カウントバグにより本来受理されるべき候補が却下された」ことだったため、**B-4を配線しても今回観測された却下の大半は解消しない**（LLMは既に式目上正しい候補を提案できていたが、判定側のバグで弾かれていた） | 中規模：`RengasController#create`・`observe_production_hyakuin.rb`双方で`checker.next_constraints(history)`を呼び、結果を`constraints:`に統合する配線作業。呼び出しタイミング（history構築後・RengaGenerator呼び出し前）の整理が必要 |

## 7. T7: B-3 / B-4 優先順位の提案（採否は人間判断・実装は今回着手しない）

### 提案：新発見の履歴構築バグ（B-3'）を最優先、B-4はその次

**根拠：**

1. **B-3'（`build_verse_history`の直前句二重カウントバグ）は、実害が定量化されており
   （句数ng却下17件中8件＝47%が誤却下）、かつ修正範囲が局所的（`fetch_verse_chain`が
   既に`previous_renga_id`自身を含んでいるため、`maeku`の再追加を除去する数行の
   修正で足りると推測される）。verse34の5回連続却下→forced_zatsuエスカレーションは
   このバグの直接の産物であり、**「本来なら正常ループで1回で通っていたはずの句が、
   バグにより5回却下されOllama呼び出しが浪費された上、最終的に季節を放棄した雑句に
   置き換わった」**という具体的な悪影響が確認できる。優先度を上げる根拠として最も強い。
2. **B-4（next_constraints配線）は構造的な欠落として実在するが、Run5データにおける
   却下の主因ではなかった**（句数ng却下の主因はB-3'であり、B-4未配線が直接の原因では
   ない）。ただし句去ng（4件、19%）はforbidden_bui配線があれば事前に回避できた
   可能性があり、無関係ではない。B-4の効果はRun5データだけでは十分に検証できず、
   B-3'修正後に改めて観測しないと真の効果が測れない。
3. **依存関係：** B-3'を先に直せば、次回観測時の句数ng発生率が下がり、B-4配線の
   効果測定（句去ng・季節転換の適切性）がノイズなく評価しやすくなる。逆にB-4を
   先に配線すると、B-3'由来の誤却下がノイズとして残ったまま効果測定することになり、
   「B-4が効いたのかB-3'由来のノイズがたまたま減っただけか」の切り分けが難しくなる。

**結論として提案する順序：B-3'（履歴構築バグ修正）→ 観測 → B-4（next_constraints配線）→ 観測。**
どちらも今回は実装せず、次回以降、それぞれ専用の依頼書を作成してから着手すること。

### 未解決の論点（人間判断が必要）

- B-3'は今回の依頼書が想定していた「B-3（D-19-5対応）」とは異なる場所・異なる
  メカニズムのバグである。依頼書のB-3という呼称をそのままこのバグに転用してよいか、
  新しい番号（例：D-41-1）を割り当てるべきかは人間の判断を仰ぎたい
- A系統（rescue範囲見直し・stderrキャプチャ、其の四十バックログ）とB-3'の
  どちらを次に着手すべきかも、本分析の範囲外のため別途判断が必要

## 7-1. 追記（其の四十二完了・2026-07-17）

T7で発見した`build_verse_history`前句二重カウントバグは、D-41-1として
`docs/architecture_decisions.md`に記録の上、其の四十二（同日、専用の依頼書
`docs/依頼書_其の四十二_build_verse_history二重カウント修正.md`）で修正済み。
`build_verse_history`末尾の`maeku`追加に`if chain.empty?`ガードを追加する
1行修正。D-33-1の人間承認プロセスに従い、修正案（diff）を人間に提示・承認を
得てから実装した。回帰テスト（`spec/controllers/rengas_controller_spec.rb`）で、
本ドキュメント§4-2の8件の誤却下パターン（verse30×2・34×5・56×1相当）が
解消されること、kukazo_under系（verse21相当）の判定結論が変わらないことを
実データで検証済み（11 examples全成功）。`verify_shikimoku.rb`は88 pass/0 fail維持。

**B-4（next_constraints配線）着手の準備は整った。** ただし着手前に、D-41-1修正後の
挙動を改めてRun5相当の観測で確認し、句去ng・句数ng残存分の発生状況を見てから
進めることを引き続き推奨する（§7参照）。

## 8. 観測基盤の不安定性（一行記録）

`sono39_observe_run3`・`sono39_observe_run4`というtmuxセッション名は存在するが、
対応するログファイル・DBレコードが一件も見つからなかった（起動されたが観測データが
生成されなかったと推測される）。深追いはせず、事実のみ記録する。

## 9. 作業ログ

| 日時 | タスク | 結果 | メモ |
|---|---|---|---|
| 2026-07-17 | ゲートチェック | 88 pass / 0 fail、tmux ls確認 | run2セッション・ログ不在を発見、人間に確認の上run5を分析対象に変更 |
| 2026-07-17 | T1: Run5完走確認 | 72/100句、tmuxペイン空・プロセス消滅（其の四十と同状態） | 変化なし |
| 2026-07-17 | T2/T3: ng却下頻度・違反種別集計 | script/analyze_sono41.rb新設。主ループng率36.7%、字数ng0件・式目ng21件 | モーラng調整は内部ループで吸収されるという構造を確認 |
| 2026-07-17 | T4: D-19-5実害確認 | 隣接ペア限定は解消済みだが、build_verse_historyの直前句二重カウントバグを発見。句数ng却下の47%(8/17)が誤却下と定量化 | 実機再現・検証済み。RengasController本体のため今回は修正せず |
| 2026-07-17 | T5: next_constraints配線調査 | 本番・observe_production_hyakuin.rbいずれも未配線。dryrun_hyakuin.rbのみ配線済みと確認 | 読み取り専用、コード変更なし |
