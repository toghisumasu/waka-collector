# 其の三十八 追加調査報告：RengaChecker（C層式目チェック）の現状

**作成:** 2026-07-15（其の三十八・続）
**位置づけ:** `report_sono38_chousa.md`の続き。同報告3節で判明した
「D-19-5の当事者はShikimokuCheckerではなくRengaChecker」という事実を受けた追加調査4点。
D-33-1に基づき、実装（手順2）にはまだ着手していない。

---

## 1. RengaChecker#check の戻り値の形式

`app/services/renga_checker.rb:7-18`

```ruby
def check
  raw = OllamaClient.generate(build_prompt)
  json = raw.match(/\{.*\}/m)&.to_s
  parsed = JSON.parse(json)
  {
    "result"    => parsed["result"],   # "ok" または "ng"（LLMの自己申告、文字列キー）
    "issues"    => Array(parsed["issues"]),
    "breakdown" => Array(parsed["breakdown"])
  }
rescue JSON::ParserError, TypeError
  { "result" => "unknown", "issues" => ["式目チェックの解析に失敗しました"], "breakdown" => [] }
end
```

- キーはすべて**文字列**（`ShikimokuChecker`のviolation Hashが使うsymbolキーとは形式が異なる）
- `result`は`"ok"` / `"ng"` の2値に加え、JSON解析失敗時の`"unknown"`が実質3値目として存在する
- `ng`理由の構造は**LLMが自由記述した文字列の配列**（`issues`）であり、`ShikimokuChecker`の
  violation Hash（`{type:, ...}`など構造化データ）のような機械可読な理由コードは持たない
- `breakdown`は「各句 → 季・種類」の説明文字列配列で、判定理由というより注釈に近い
- プロンプト内で`result`が`ok`/`ng`のどちらかになるよう指示しているが、**コード側でのバリデーションは無い**
  （LLMが指示外の値を返してもそのまま格納される）

---

## 2. RengaGenerator / RengasController内でのリトライループへの組み込み

**結論：組み込まれていない。** `RengaChecker#check`は`rengas_controller.rb:52`で
**1回だけ**呼ばれ、結果は判定にもリトライにも使われず、そのまま`Renga.create!`の
`style_check_result`に格納されるのみである。

```ruby
# rengas_controller.rb:48-63
tsugeku = RengaGenerator.new(...).generate_tsugeku
result  = RengaChecker.new([maeku, tsugeku]).check   # ← 結果は使い捨てではないが、分岐もリトライもしない

@renga = Renga.create!(
  ...,
  style_check_result: result,   # ← ngでもwarningでも、そのまま保存される
  ...
)
```

`if check[:result] == "ng"` という分岐は**同じメソッド内に存在するが、それは
`KuValidator`（字数検証）の結果に対してのみ**（`rengas_controller.rb:28-43`）であり、
`RengaChecker`の`result`に対する分岐は一切ない。`RengaChecker`がngを返しても
リクエストは失敗せず、そのまま連歌として保存・表示される（3節参照）。

`RengaGenerator#generate_tsugeku`（`app/services/renga_generator.rb`）は
`mora_error_streak` / `repeat_streak` / `wrong_streak` という3つのストリークを持つ独自の
リトライ機構を持つが、いずれも**RengaCheckerとは無関係**：

| ストリーク変数 | スコープ | 何をカウントするか | RengaCheckerとの関係 |
|---|---|---|---|
| `mora_error_streak` | `generate_tsugeku`全体（外側5回×内側5回をまたいで維持） | 目標音数から±1音を超えた回数（`KuValidator`相当の自前カウント） | 無関係 |
| `repeat_streak` | 同上 | `history_repeat?`（Levenshtein距離、其の三十六）が一致/類似と判定した回数 | 無関係 |
| `wrong_streak` | 外側`5.times`ループ内でリセット（seed再抽選ごとに0に戻る） | echo/鸚鵡返し/固着/既出の連続回数 | 無関係 |

依頼書が想定していた「`duplicate_streak`」という変数名は**コード中に存在しない**。
実際に似た役割を持つのは上記`wrong_streak`（`is_sticky`判定＝直近の重複使用回数）だが、
これも`RengaChecker`ではなく`RengaGenerator`内部の自前ロジック（`used_afters.count`・
`all_attempts.count`）で完結しており、`RengaChecker`の判定結果は関与しない。

まとめると、**`RengaGenerator`側のリトライは全て生成前の自己検証（音数・既出チェック）で
完結しており、`RengaChecker`（生成後のLLM式目チェック）はそのループの外側、
生成が確定したあとに1回だけ呼ばれる「事後ラベリング」**という位置づけである。

---

## 3. LLMへの再生成フィードバック文言の組み立て箇所

`RengaChecker#check`の失敗（`result: "ng"`）を受けての再生成フィードバックは
**存在しない**。2節の通り`RengaChecker`の結果はどこでも分岐に使われないため、
その結果を使ってプロンプトを組み立て直す経路自体がコード上に無い。

`build_full_prompt`（`renga_generator.rb:380-407`）が組み立てる`feedback_line`は、
`RengaGenerator#generate_tsugeku`内で**自前検出した**mora不一致・echo・鸚鵡返し・
固着・既出（history_repeat）に対するものであり、`RengaChecker`（別クラス・別プロンプト・
別LLM呼び出し）の判定結果は一切参照していない。`socratic_mora_messages` /
`socratic_repeat_messages`も同様に、`RengaGenerator`内部のstreak変数だけを見て
組み立てられている。

つまり「RengaCheckerが式目違反ありと判定した場合に、その`issues`をプロンプトへ
差し戻す」というフィードバックループは**未実装**であり、これも1節の`result`が
判定にも再生成にも使われていないという事実と整合する。

---

## 4. style_check_result カラム（DB）とview表示

**保存：** `RengaChecker#check`の戻り値を**加工せずそのまま**格納している。
`rengas_controller.rb:60`の`style_check_result: result`が、1節の3キーHash
（`"result"` / `"issues"` / `"breakdown"`、いずれも文字列キー）をそのまま渡している。
カラム型は`jsonb`（`db/migrate/20260607005905_create_rengas.rb:8`、
`db/schema.rb:23`）で、デフォルト値やNOT NULL制約は無い。

**表示：** `app/views/rengas/show.html.erb`が3箇所で参照している。

```erb
<!-- 見出し判定（26-38行目） -->
shikimoku_result = @renga.style_check_result["result"]
shikimoku_ok     = shikimoku_result == "ok"
...
elsif shikimoku_result == "ng"
  "連歌不成立"
...

<!-- 式目チェックセクション（68-84行目） -->
<% res = @renga.style_check_result %>
<p>結果：<strong><%= res["result"] %></strong></p>
<% if res["issues"].present? %>
  ...res["issues"].each { |issue| ... } ...
<% end %>
<% if res["breakdown"].present? %>
  ...res["breakdown"].each { |b| ... } ...
<% end %>
```

- viewは1節の3キー（`result`/`issues`/`breakdown`）をそのまま前提にしており、
  `RengaChecker`の出力形式と**密結合**している。仮に(B)案（`RengaChecker`プロンプトへの
  履歴注入）を採ってもキー構造自体は変えない限りviewの変更は不要
- `result`が`"unknown"`（JSON解析失敗）の場合、`shikimoku_ok`は`false`になるが
  見出し分岐は`shikimoku_result == "ng"`にも一致しないため、末尾の`else`節
  （「連歌成立（式目チェック未確定）」）に落ちる。3値のうち`unknown`だけがこの
  フォールバック文言を通る設計になっている
- DBには生の`RengaChecker`結果がそのまま蓄積されるため、過去データを見れば
  「何回ngが出ていたのに保存され表示されていたか」を後から集計できる
  （2節の通り、ng判定は保存を止めない）

---

## 所見（判断が必要な点への追加情報）

`report_sono38_chousa.md`末尾の「判断が必要な点」1.で(B)案
（`build_verse_history`→`RengaChecker`プロンプト注入）を選んだ場合、
今回の調査で以下が追加の実装対象になることが分かった。

- `RengaChecker#check`の`result`を`rengas_controller.rb`で**分岐に使う経路が
  そもそも無い**ため、(B)を「D-19-5の誤判定を減らす」で終わらせず「ng時にどうするか」
  まで実装するなら、リトライ or 警告表示のいずれかを新設する必要がある
  （現状は生成後の事後ラベリングのみで、ngでも保存・表示は止まらない）
- (B)で`RengaChecker`にhistory由来の情報を渡す場合、`build_prompt`
  （`renga_checker.rb:22-52`）の`list`は現状`[maeku, tsugeku]`の2句固定であり、
  複数句の履歴を渡す形にプロンプト構造自体を変更する必要がある
- view側（`show.html.erb`）はキー構造にのみ依存しており、(A)(B)いずれの案でも
  `result`/`issues`/`breakdown`という3キー形式を維持する限り変更不要

以上、D-33-1に基づきここで一旦停止する。
