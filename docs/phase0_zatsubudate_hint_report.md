# Phase 0 調査報告：雑部立ヒント配線（其の六十三）

調査日：2026-07-25
調査範囲：読み取りのみ（`app/`・`config/`・DBスキーマへの変更なし）
ゲート確認：`bundle exec ruby script/verify_shikimoku.rb` → **98 pass / 0 fail**
（依頼書記載の「88 pass」より増えているが、CLAUDE.md記載の通り「数は増える」仕様のため0 failであれば異常なし）

---

## 1. next_constraints 現行構造

`app/services/shikimoku_checker.rb:459-465`

```ruby
def next_constraints(history, bui_dict: nil)
  {
    verse_type:    next_verse_type(history),
    forbidden_bui: compute_forbidden_bui(history),
    season_hint:   compute_season_hint(history)
  }
end
```

### 返り値のハッシュ構造

| キー | 型 | 値域 |
|:--|:--|:--|
| `verse_type` | Symbol | `:chouku` / `:tanku`（`history`が空、または直前句の`verse_type`がnilなら`:tanku`固定） |
| `forbidden_bui` | Array\<String\> | `kuzari_rules.yml`のキー名のうち、直近の再出現間隔が規定句去数未満のもの（`uniq`済み） |
| `season_hint` | Hash | `{ current: String\|nil, count: Integer, must_continue: Bool, must_switch: Bool }`。直前句が`nil`または`"雑"`なら`{ current: nil, count: 0, must_continue: false, must_switch: false }` |

`bui_dict:`引数は現状**未使用**（メソッド内で一度も参照されない）。将来の部立判定強化用に予約されている形跡だが、Phase 0時点ではデッドパラメータ。

### 呼び出し元一覧

| ファイル | 行 | 用途 |
|:--|:--|:--|
| `app/controllers/rengas_controller.rb:61` | Web本番経路（`create`アクション） | `history`を`build_verse_history`から構築し渡す |
| `script/observe_production_hyakuin.rb:225` | 観測スクリプト（D-50-1で本番と同型に配線済み） | 同上 |
| `script/dryrun_hyakuin.rb:370` | ドライラン検証スクリプト | 同上（ただし`RengaGenerator`を`require`しないため本番相当の検証には使えない、[[production_code_frozen]]参照） |
| `script/verify_shikimoku.rb:686-698`（試陸91） | ゲートテスト | 初折表pos1〜6の`history`を渡し、`season_hint`等の単体テスト |

いずれも`checker.next_constraints(history)`の形で呼び、返り値を`RengaGenerator.new(..., constraints: { forbidden_bui: ..., season_hint: ... })`に詰め替えて渡している。呼び出しパターンは3箇所（controller・observeスクリプト・verify）で完全に同型。

**補足（architecture_decisions.md 503-509行との齟齬）：** D-19-1章の記述時点（其の四十四）では「`observe_production_hyakuin.rb`への配線は対象外」とされていたが、其の五十（D-50-1）で実際には配線済みになっている。ドキュメントが後続コミットに追随していない箇所であり、雑部立ヒントの配線先を検討する際はこの現状（2スクリプトとも配線済み）を前提にすること。

### 引数として何を受け取っているか

`history: Array<Hash>`のみ（`bui_dict`は未使用）。各要素は以下の形（`rengas_controller.rb:169-170`）：

```ruby
{ bui: Array<String>, season: String|nil, verse_type: Symbol,
  word: String|nil, text: String, plant_type: String|nil }
```

`history`は**連鎖全体ではなく直近最大8句**に切り詰められている（後述P0-2で詳述）。句番・折・履歴中の位置を示す情報は一切含まれない。

---

## 2. 参照可能情報の棚卸し

### 現在の句番（何句目か）を知る手段

**内部に手段なし。** `next_constraints`/`compute_forbidden_bui`/`compute_season_hint`はいずれも`history.size`か`history.reverse_each`のみを使い、絶対句番（1〜100のうち何句目か）を返す・参照する仕組みが存在しない。

さらに重要な制約として、`history`自体が**絶対句番と対応していない**：

`app/controllers/rengas_controller.rb:135-155`の`fetch_verse_chain`は`limit: 9`で呼ばれ（`build_verse_history`内、163行目）、depth_guard `WHERE verse_chain.depth + 1 < 9`により**直近最大8句分**しか取得しない。100句本番実行で50句目にいても、`next_constraints`に渡る`history.size`は最大8にしかならない。

現に`script/observe_production_hyakuin.rb`側では、真の句番は**呼び出し側のループ変数`verse_no`**（186行目 `(1..TOTAL_VERSES).each do |verse_no|`）で管理されており、`next_constraints`にもchecker内部にもverse_noは渡っていない（`log_season_hint(next_constraints, verse_no: verse_no)`のように**呼び出し側が別途保持する値として後付けで渡している**、`season_hint_logger.rb:8`）。

**最小変更での実現方法：** `next_constraints(history, verse_no:)`のようにキーワード引数で明示的に渡すのが最小。呼び出し元（controller・observeスクリプト双方）は既に`verse_no`相当の値（`history.size + 1`または`verse_no`ローカル変数）を握っているため、引数追加のみで済む。ただし前述の通り`history.size`は絶対句番と一致しないため、`history.size + 1`を句番の代用にする現行`log_season_hint`呼び出し（`rengas_controller.rb:62`）は**Web本番経路では実は正しくない**（該当箇所は`history.size + 1`＝直近チェーン長+1であり、真の句番ではない）。この点は雑部立ヒント設計が「初表1〜8句」等の絶対句番依存ルールを持つ以上、看過できない既存ギャップである。

### 折（初表／初裏／二の折…）の判定手段

**存在しない。** `teiza_tsuki_violations`/`teiza_hana_violations`（`shikimoku_checker.rb:298-315`）は`faces`/`folds`という引数を外部（呼び出し側）から渡される前提で、`ShikimokuChecker`自身は折の境界定義（1..8, 9..22, ...）を一切持たない。`script/verify_shikimoku.rb:623-639`にテスト用の`tsuki_faces`/`hana_folds`定数があるのみで、本番コード（`app/`配下）には折の境界定義が存在しない。

「初表＝1〜8句」という定義は`verify_shikimoku.rb`のテストデータ内にのみ存在し、本番経路で参照可能な定数・設定は現状ゼロ。

### 「直近で恋／旅／述懐が出た句番」を得る手段

**部分的に存在する。** `compute_forbidden_bui`と同じパターン（`history`を逆順に走査し`bui`配列に対象タグを含む最後の位置を探す）を流用すれば、`history`内で恋／旅／述懐が最後に出た**相対位置**（history配列内のindex）は求められる。ただし：

1. `history`が直近8句に切り詰められているため（P0-2冒頭参照）、8句より前に最後に出現した場合は`history`内に痕跡がない。
2. `bui`配列自体に恋・述懐タグがほぼ載らない（P0-3で詳述）。

そのため「直近未使用の間隔」を正確に計算するには、a) `history`の切り詰め上限を広げる（少なくとも恋の句去5句・句数上限5句を超える幅、実測では8句以上の間隔も観測されているため安全側で20句程度は欲しい）、b) DBから直接取得する、のいずれかが必要。

---

## 3. 部立判定の実情（恋・旅・述懐）

### BuiDictionaryでの判定可否

`app/data/bui_dictionary.yml`（218行）を全文確認した結果：

| 部立 | 登録語数 | 登録語 |
|:--|:--|:--|
| 恋 | **0件** | （登録なし） |
| 旅 | 5件 | 旅／旅衣／草枕／旅路／旅人 |
| 述懐 | **0件** | （登録なし） |

`BuiDictionary#detect_all`（`app/services/bui_dictionary.rb:55-65`）はMeCab形態素の表層形を`primary_bui`に完全一致照会するのみ（D-38-3・D-36-1）。**恋・述懐は辞書に一件も登録されていないため、現行コードでは`bui`配列に`"恋"`または`"述懐"`が入ることは構造的にあり得ない。** 旅も5語のみで、`旅`を含む複合語（例：ひらがな「たび」、「旅寝」「旅先」等）はヒットしない。

これは`kuzari_rules.yml`・`kukazo_rules.yml`双方に恋・旅・述懐の規則が定義されているにもかかわらず（後述）、**実データでは発火し得ない「死んだルール」になっている**ことを意味する。`renga_generator.rb`の`KIGO_BUI`定数（部立の第二の情報源、47-60行）にも恋・述懐は一切登場しない。

### kuzari_rules.yml / kukazo_rules.yml上の扱い

`app/data/kuzari_rules.yml`：

```yaml
恋: 5
旅: 5
述懐: 5
```
（句去＝5句の間隔規制。他の人倫系部立と同じ扱い、植物のような細分化なし）

`app/data/kukazo_rules.yml`：

```yaml
bui:
  恋:
    max: 5
  旅:
    max: 3
  述懐:
    max: 3
```
（連続上限。恋のみ春秋と同格の5句、旅・述懐は夏冬などと同格の3句）

**規則自体は連歌新式に忠実に定義済み**だが、上記の通り検出経路（BuiDictionary）が空のため実質デッドコード。依頼書が求める「雑部立ヒント」は既存句去・句数ルールの発火を補う新設ロジックとして設計する必要がある（既存ルールの手直しでは足りない）。

### D-22-2（ひらがな取りこぼし）の影響見立て

D-22-2は「ひらがな表記語が辞書エントリ（漢字表記）にヒットしない」問題（`docs/architecture_decisions.md:717-731`、実例：「やしろ」が「社」にヒットしない）。

恋・述懐については**そもそも辞書登録がゼロ**なので、D-22-2以前の問題（ひらがな/漢字を問わず検出手段が存在しない）。旅については5語すべて漢字表記のため、ひらがな「たび」「たびごろも」等はD-22-2と同型のギャップとして今後発生し得る。ただし恋・述懐の欠落の方が影響が大きく優先度が高い。

### 其の六十二の実証データ（参考）

`script/aggregate_koitabijukkai.rb`を実行し、独吟2作品（遺誡百韻・住吉夢想百韻）の恋・旅・述懐の出現間隔を確認した（依頼書5項「対象は独吟モードの閾値のみ」に対応する一次データ）：

| 作品 | 部立 | 初出句番 | 最短間隔（初出後） |
|:--|:--|:--|:--|
| 遺誡百韻 | 恋 | 21句目 | 8句 |
| 遺誡百韻 | 旅 | 4句目 | 6句 |
| 遺誡百韻 | 述懐 | 16句目 | 6句 |
| 住吉夢想百韻 | 恋 | 21句目 | 15句 |
| 住吉夢想百韻 | 旅 | 2句目 | 5句 |
| 住吉夢想百韻 | 述懐 | 32句目 | 22句 |

両独吟作品とも恋の初出は**21句目**（初表1〜8句を明確に外れている）で、依頼書の「恋は初表では提案しない」という前提と整合する。実測される最短間隔は恋8句・旅5句・述懐6句で、`kuzari_rules.yml`記載の一律5句よりも恋は実際には長めに空いている。閾値設計の参考値として報告書に残す（Phase 0では数値を確定させない）。

---

## 4. 連鎖履歴データ構造

### build_verse_historyの返す構造

`app/controllers/rengas_controller.rb:162-182`

```ruby
def build_verse_history(previous_renga_id, maeku, maeku_type, nm: build_mecab, bui_dict: BuiDictionary.new)
  chain = fetch_verse_chain(previous_renga_id, limit: 9)   # ← 直近最大8句(depth 0-7)
  history = chain.each_with_index.map do |r, i|
    ...
    { bui: bui_dict.detect_all(text, nm), season: season_from_text(text), verse_type: vtype,
      word: word, text: text, plant_type: bui_dict.plant_type(word) }
  end
  ...
  history
end
```

各要素は`bui`（配列）・`season`・`verse_type`・`word`・`text`・`plant_type`を持つが、**句番（絶対位置）・折情報は含まない**。`bui`配列は前述の通り恋・述懐が事実上入らない。

### 部立の出現履歴を再構成できるか

`history`の`bui`フィールドから恋／旅／述懐の出現履歴を再構成する仕組み自体は（`current_bui_streak`と同型のロジックで）作れるが、以下2点が障害になる：

1. **`limit: 9`による切り詰め** — 直近8句を超えて遡れない。恋の句去規制（5句去）・連続上限（5句）だけなら8句で足りるが、雑部立ヒントが要求する「直近未使用の間隔」判定（実測で8〜22句の間隔が観測される）には全く足りない。
2. **恋・述懐がbui配列に入らない** — BuiDictionary側の登録追加が前提条件になる（P0-3参照。ただし依頼書の「禁止範囲」によりYAML辞書編集はPhase 0外）。

### DBから引くのと、履歴構造を拡張するのと、どちらが小さいか

- **DBから引く案：** `fetch_verse_chain`の`limit`を外す（または恋の閾値以上の値に拡大）だけで済み、`Renga`テーブルの列追加は不要（`tsugeku`本文から`BuiDictionary#detect_all`で都度部立を再計算できる）。ただし1クエリで全履歴（最大100行）を毎回引くことになり、既存の「limit: 9で式目チェック用に絞る」設計意図（コメント133-134行）から外れる。パフォーマンス上は無視できる規模（百韻=最大100行）。
- **履歴構造拡張案：** `history`各要素に`pos:`（絶対句番）を追加するだけなら影響範囲は小さいが、それだけでは「直近8句」の制約自体は解消されない。恋・述懐の間隔判定には結局`limit`緩和とセットにする必要がある。

**所見：** 差分規模は「`fetch_verse_chain`の`limit`引数を緩和 or 撤廃」の方が「履歴構造そのものを拡張」より小さい。`limit: 9`という値自体が「式目チェックに必要な最大句去数（5句）+バッファ」を想定した designed constant と推測されるため、雑部立ヒント用に別途「恋・旅・述懐だけ全履歴を見る」経路を足す方が、既存の句去・句数チェック用`history`を汚染せず安全（案は第6章で後述）。

---

## 5. プロンプト注入点と影響範囲

### forbidden_bui / season_hintが文言化されている箇所

`app/services/renga_generator.rb`

| 変数 | 生成箇所 | 用途 |
|:--|:--|:--|
| `forbidden_bui` | 109行（`generate_tsugeku`内で`@constraints[:forbidden_bui]`取得） | プロンプト禁止語生成の元 |
| `forbidden_label` | 110行 | `forbidden_bui.join("・")` |
| `season_hint` | 108行 | `must_switch`判定によるseason_label切替（148-152行） |
| `kinshi`（禁止語文言） | **389-394行**（`build_full_prompt`内） | `"禁：#{desc}の語は避けること。\n"` |
| `filter_pool`内の`forbidden_bui`利用 | 340-347行 | プロンプト注入ではなくシード候補プール自体のフィルタ（B層） |
| `kigo_hint`内の`forbidden_bui`利用 | 414-423行 | 季語ヒント候補から禁止部立の季語を除外 |

`build_full_prompt`（385-412行）の実際の出力テンプレート：

```
前の句と合わせて短歌一首になるような続きを作れ。   ← D-19-1冒頭指示行（405行目）
前句：#{@maeku}
連想：#{seed[:surface]}
季節：#{season_label}
#{kigo_line}#{kinshi}#{feedback_line}#{target_desc}を一行だけ出力せよ。説明不要。
続き：
```

`season_hint`/`forbidden_bui`はいずれも`kigo_line`・`kinshi`という**冒頭指示行より後の行**として挿入されており、405行目自体には触れていない。

### 新フィールドを1つ増やした場合の影響範囲

`forbidden_bui`と同じ「制約→文言化」パターンを踏襲する場合、想定される変更箇所：

1. `shikimoku_checker.rb`：`next_constraints`に新キー（例：`bui_hint`）を追加、算出用privateメソッドを1つ新設（`compute_forbidden_bui`と同程度の規模、30〜40行程度）。
2. `rengas_controller.rb` / `script/observe_production_hyakuin.rb`：`constraints: {...}`ハッシュに新キーを1行ずつ追加（各1行、計2箇所）。
3. `renga_generator.rb`：`generate_tsugeku`内で新規制約を取り出す行（108-110行と同様、+1〜2行）、`build_full_prompt`内に新しい文言生成ブロック（`kinshi`と同型、+5〜10行）、テンプレート内に埋め込み行を1行追加。
4. `script/verify_shikimoku.rb`：ゲートテストに新規ケースを追加（既存の`season_hint`テスト＝試陸91相当の分量、+20〜40行）。

見積り規模：**本体ロジック追加40行程度＋配線6箇所（各1〜10行）＋テスト20〜40行**。既存の`season_hint`追加時（D-44-1）と同程度のオーダーと推測される。

### D-19-1冒頭指示行への影響

**影響なし。** `forbidden_bui`/`season_hint`が現にそうしているのと同じ位置（`kigo_line`/`kinshi`と同格の新しい行）に追記する限り、405行目「前の句と合わせて短歌一首になるような続きを作れ。」自体は変更不要。ただし依頼書の禁止範囲（D-19-1冒頭指示行の編集禁止、調査時も編集禁止）を厳格に守るなら、実装フェーズでもこの行だけは絶対に触らないことを設計時点で明記しておくべき。

---

## 6. 配線案（案A／案B）と推奨

### 案A：next_constraintsの返り値に新キー（`bui_hint`）を追加

```ruby
def next_constraints(history, bui_dict: nil)
  {
    verse_type:    next_verse_type(history),
    forbidden_bui: compute_forbidden_bui(history),
    season_hint:   compute_season_hint(history),
    bui_hint:      compute_bui_hint(history, verse_no: ...)   # 新設
  }
end
```

- **差分規模：** 小〜中。既存メソッドと同じファイル・同じ形（Hash返却）に収まるため、呼び出し側（controller・observeスクリプト）の変更は「新キーを1行extractして`constraints`に足す」だけで済む。`season_hint`が辿った実装パターンをそのまま踏襲できる（実績あり）。
- **ゲートへの影響：** `next_constraints`の返り値構造が変わる（キー追加）が、既存キー（`verse_type`/`forbidden_bui`/`season_hint`）は不変のため、既存の試陸91等の既存テストは**壊れない**（Hashへのキー追加は既存の`c[:season_hint]`等の参照に影響しない）。新規テストケースの追加のみで済む。
- **ロールバック容易性：** 高い。新キーを無視すれば（`RengaGenerator`側で読まなければ）実質何も変わらない。`next_constraints`メソッド自体を元に戻す差分も1メソッド分で完結。

### 案B：next_constraintsは触らず、別メソッド／別オブジェクトとして分離

```ruby
def next_bui_hint(history, verse_no:)
  # 恋・旅・述懐の提案タイミングだけを返す独立メソッド
end
```

呼び出し側は`checker.next_constraints(history)`と`checker.next_bui_hint(history, verse_no: ...)`を別々に呼ぶ。

- **差分規模：** 中。`next_constraints`本体には一切触れないが、呼び出し元（controller・observeスクリプト双方）に新しい呼び出し行が増える（案Aの「1キー追加」より呼び出し側の変更点が1箇所多い：メソッド呼び出し自体を追加する必要がある）。
- **ゲートへの影響：** ゼロ。既存`next_constraints`の入出力に一切触れないため、既存テスト（試陸91含む）への影響が構造的にあり得ない。新設メソッドの単体テストのみ追加。
- **ロールバック容易性：** 最も高い。新設メソッド・呼び出し行を削除するだけで完全に元通り。`next_constraints`自体の差分すら発生しない。

### 推奨

**案B（別メソッド分離）を推奨する。**

理由：
1. 依頼書3節の不変条件「D-33-1：本番構造コードの変更は差分提示と人間承認を経ずに行わない」の観点で、`next_constraints`という3箇所から呼ばれる既存の共有インターフェースを変更する案Aより、影響範囲が独立した新設メソッドの方が承認・レビューの単位を小さく保てる。
2. `bui_hint`の性質が`season_hint`/`forbidden_bui`と異なる。既存2キーは「直近history（最大8句）」の範囲で完結する計算だが、雑部立ヒントは第2〜4章で確認した通り**絶対句番（初表1〜8句除外）**と**8句を超える間隔追跡**を要求する、根本的に異なるデータ依存を持つ。同じ`next_constraints`に無理に同居させるより、要求データ（`verse_no`・拡張履歴）が異なることを型として明示できる別メソッドの方が設計上素直。
3. 案Aでも壊れないとはいえ、`next_constraints`は3箇所の呼び出し元すべてに影響しうる中心的メソッドであり、そこに手を入れる変更は他の2キー（forbidden_bui/season_hint）の将来の改修時にコンフリクトしやすい。

ただし、`RengaGenerator`側の`@constraints`ハッシュへの積み込み方（案Aのように1つのHashに統合するか、`bui_hint`用に別引数を増やすか）は実装フェーズでの検討課題として残す。

---

## 7. 未解決事項・人間の判断を仰ぐ点

1. **依頼書が参照する`docs/設計メモ_雑部立ヒント方針たたき台_其の六十二.md`が存在しない。** リポジトリ全体（`docs/`配下、`git log --all`）を検索したが該当ファイルは見つからなかった。「別添」とあるが未コミット・未共有の可能性がある。方針の詳細（恋×述懐同時提案禁止のロジック等、依頼書1節の要点以上の設計意図）はこのメモに書かれている前提で依頼書が書かれているため、内容を別途共有いただくか、依頼書1節の再掲内容のみを設計根拠として進めてよいか確認したい。

2. **`history.size + 1`を句番として使っている既存コード（`rengas_controller.rb:62`の`log_season_hint`呼び出し）が、Web本番経路では絶対句番と一致しない。** これは雑部立ヒント固有の問題ではなく既存のD-44-1配線に内在するギャップだが、雑部立ヒントが絶対句番（初表1〜8句除外等）に依存する設計である以上、この既存ギャップをPhase 0の範囲内で放置してよいか、それとも雑部立ヒント実装の前提条件として先に修正すべきか、判断を仰ぎたい。

3. **`build_verse_history`の`limit: 9`を緩和する場合のパフォーマンス・設計方針。** 第4章で述べた通り、恋・旅・述懐の間隔判定には少なくとも8〜22句規模の履歴参照が必要（実測値）。既存の句去・句数チェック用historyとは異なる用途のため、①`limit`自体を緩和して既存historyを流用する、②恋・旅・述懐専用に別途DBから取得する経路を新設する、のどちらを採るべきかは実装フェーズでの設計判断が必要（Phase 0では両論併記に留める）。

4. **恋×述懐同時提案禁止のロジックをどこで持つか。** 依頼書1節に要件として書かれているが、これは単一句のbui判定だけでは足りず「複数部立候補の組み合わせ制約」であり、既存の`kuzari_violations`/`kukazo_violations`のような単一部立ごとのチェックとは設計が異なる。案A/案Bいずれの配線でも、この組み合わせ制約をどこに実装するか（`bui_hint`計算メソッド内で完結させるか、`RengaGenerator`側のプロンプト文言生成時に判定するか）は次フェーズで決めるべき事項として残す。

---

*関連：`docs/architecture_decisions.md`（D-19-1 / D-33-1 / D-36-1 / D-44-1 / D-22-2）、
`app/services/shikimoku_checker.rb`、`app/services/bui_dictionary.rb`、`app/data/bui_dictionary.yml`、
`app/data/kuzari_rules.yml`、`app/data/kukazo_rules.yml`、`script/aggregate_koitabijukkai.rb`*
