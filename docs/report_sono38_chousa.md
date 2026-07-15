# 其の三十八 調査報告：build_verse_historyの実接続 手順1

**作成:** 2026-07-15（其の三十八）
**位置づけ:** 依頼書（`docs/iraisho_20260715_sono38.md`）手順1の調査結果。D-33-1に基づき、
実装（手順2）には着手していない。本報告の内容を踏まえた統合方針の承認を待つ。

---

## 0. 最重要の発見（依頼書の前提の再確認が必要）

依頼書は「`build_verse_history`を`ShikimokuChecker`に接続すればD-19-5が解消する」という
前提で書かれているが、実際に呼び出し関係を確認したところ、**`ShikimokuChecker`は
`app/`配下（`RengaGenerator`・`RengasController`）から一度も呼ばれていない**。
production の式目チェックは全く別のクラス`RengaChecker`（LLMベース）が担っており、
D-19-5が指摘した「前句・付句の2句だけを見て誤判定する」バグの当事者は**こちら**である。

以下、この前提のズレを含めて依頼書指定の5点を報告する。

---

## 1. ShikimokuCheckerの公開インターフェース

| メソッド | 入力形式 | 備考 |
|---|---|---|
| `kuzari_violations(history_bui, candidate_bui, ...)` | `history_bui`: `Array<Array<String>>`（各句の部立集合、古い順）＝**配列** | 句去。後方互換の旧形式 |
| `kukazo_violations(history, candidate)` | `history`: `Array<Hash{bui:,season:}>`＝**配列** | 句数（連続上限・春秋最短規制） |
| `all_violations(history, candidate, bui_dict:)` | `history`: `Array<Hash>`＝**配列** | 句去+句数の統合 |
| `scan_chain(chain, bui_dict:)` | `chain`: `Array<Hash>`＝**配列** | 連鎖全体を先頭から逐次検査 |
| `current_bui_streak` / `current_season_streak` | `history`: `Array<Hash>`＝**配列** | ストリークカウンタ |
| `chotan_violations(history, candidate)` | `history`: `Array<Hash>`＝**配列** | 長短交互（Phase 8-2で実装済み） |
| `ichiza_violations(history, candidate, ichiza_words)` | `history`: `Array<Hash>`＝**配列** | 一座一句物（Session24実装） |
| `next_constraints(history, bui_dict:)` | `history`: `Array<Hash>`＝**配列**。戻り値`{verse_type:, forbidden_bui:, season_hint:}` | 次句生成用の制約サマリー |
| `self.describe(violation)` | 単一のviolation Hash | 表示用 |

**結論：`ShikimokuChecker`の全メソッドは、すでに「前句1つ」ではなく「履歴配列」を
受け取る設計になっている。** クラス冒頭のコメント（`shikimoku_checker.rb:15-19`）にも
「DBコールはこのクラスの外で行い、ここには配列として渡す」と明記されており、
インターフェース自体は其の十九当時から履歴配列を前提に作られていた。**引数拡張は不要。**

---

## 2. build_verse_historyの現在の出力構造（其の三十七で一本化済み）

```ruby
# rengas_controller.rb:112-121
chain = fetch_verse_chain(previous_renga_id, limit: 9)  # chain.size<9相当
history = chain.map { |r| { bui: [], season: season_from_text(r["tsugeku"]), verse_type: vtype } }
history << { bui: [], season: season_from_text(maeku), verse_type: maeku_type }
```

- 本文（tsugekuの生テキスト）は**保持しない**（`fetch_verse_chain`から取得はしているが、
  `season_from_text`に通した後は捨てる）
- `bui: []`固定（**bui検出ロジックは一切呼んでいない**）。D-36-1が予防しようとした
  「C層自己申告混入」は起きていないが、B層`BuiDictionary`による確定値もまだ入っていない、
  文字通り空の状態
- `season`は`season_from_text`（`SEASON_WORDS`の文字列マッチ、B層の簡易版）から算出
- 上限：`chain.size<9`相当（直近9句、其の三十七で承認・維持）
- 戻り値の型は`ShikimokuChecker#next_constraints`および`all_violations`が期待する
  `Array<Hash{bui:,season:,verse_type:}>`と**完全に一致**

---

## 3. RengaGenerator / RengasController内でShikimokuCheckerが呼ばれている箇所

**該当なし。** `grep -rn "ShikimokuChecker" app/`の結果は`shikimoku_checker.rb`自身と
`bui_dictionary.rb`のコメント1行のみで、実呼び出しはゼロ。

代わりに、productionの式目チェックは`rengas_controller.rb:52`の以下の1箇所だけである。

```ruby
result = RengaChecker.new([maeku, tsugeku]).check
```

`RengaChecker`（`app/services/renga_checker.rb`）は`ShikimokuChecker`とは無関係の
別クラスで、**LLM（`OllamaClient.generate`）にルール説明入りプロンプトを投げてJSON判定
を得る**方式である。プロンプトに含まれる検査対象は`[maeku, tsugeku]`の**2句のみ**
（`build_prompt`内の`list`）。D-19-5の原文（`architecture_decisions.md`）も
「**RengaChecker**が前句・付句の2句だけを見て句数を判定している」「修正時は
ShikimokuChecker#next_constraintsの季情報をRengaCheckerプロンプトにも渡す形が最小変更」
と明記しており、**バグの当事者はRengaCheckerであって、ShikimokuCheckerではない**。

これは統合先の選択に直結する重要な分岐点である。

| 統合先 | 影響範囲 | D-19-5解消への効果 |
|---|---|---|
| (A) `build_verse_history` → `ShikimokuChecker#next_constraints` → `RengaGenerator`の`constraints[:forbidden_bui]`/`constraints[:season_hint]` | 次候補の**生成誘導**（`filter_pool`・`kigo_hint`・`build_full_prompt`の禁則表示）が変わる。実際`next_constraints`の戻り値形状はこれらメソッドの期待値と完全一致しており、明らかにこの用途で設計されている | **解消しない**。生成される候補が変わるだけで、最終的に保存される`style_check_result`（RengaChecker/LLM判定）は独立したまま誤判定し得る |
| (B) `build_verse_history`の履歴（またはそこから算出した季ストリーク情報）を`RengaChecker`のプロンプトに追加コンテキストとして渡す | `style_check_result`の判定精度が変わる | **解消する**。D-19-5が名指ししていた修正そのもの |

現状どちらも未接続で、依頼書の「build_verse_historyの実接続」という文言だけでは(A)(B)
どちらを指すか一意に決まらない。D-19-5解消という依頼書の位置づけに厳密に従うなら(B)が
本命だが、(B)は「LLMプロンプトに履歴由来の情報を混ぜる」という性質上、C層の担当領域に
踏み込む（A層`ShikimokuChecker`自体は変更しないが、その出力をC層プロンプトに注入する
接着コードが新たに必要）。(A)は完全にA層/B層の範囲内で完結し、`ShikimokuChecker`を
"死んだコード"から救い出す意味はあるが、依頼書が問題視したD-19-5の誤判定そのものは直さない。

---

## 4. 一座一句物（ichiza_violations）との関係

`ichiza_violations(history, candidate, ichiza_words = @ichiza_words)`はSession24時点
から既に`history`を配列（`Array<Hash>`、確定済み句列全体）で受け取る3引数形式である。
呼び出し箇所は`script/dryrun_hyakuin.rb:591`と`script/verify_shikimoku.rb`のみで、
こちらも**production未接続**（3の`ShikimokuChecker`全体未接続という状況と同じ）。
今回`build_verse_history`を(A)の形で接続すれば、`ichiza_violations`も同じ`history`配列
をそのまま渡せる位置になり、**役割重複はない**（`all_violations`が句去・句数を、
`ichiza_violations`が一座一句物を担当する不可分の別チェックとして設計されている）。
むしろ(A)を実装するなら、`ichiza_violations`も同じ接続点に自然に乗る形になる。

---

## 5. 其の三十六の逆戻り検知専用経路との関係（所見）

`fetch_verse_history`（Levenshtein判定用、文字列配列）と`build_verse_history`
（`ShikimokuChecker`用、`{bui:,season:,verse_type:}`配列）は、其の三十七で**行取得の
土台**（`fetch_verse_chain`）のみ共有し、出力形状は独立を維持している。

今回の接続作業でもこの独立を維持するのが自然だと考える。理由：

- `verse_history`（Levenshtein用）は生テキストの配列で完結し、bui/season情報を一切
  必要としない
- `build_verse_history`側にbui情報を足す場合はD-36-1（B層`BuiDictionary`確定値限定）
  に従う必要があり、これは逆戻り検知（Levenshtein）とは無関係な制約
- 両者を1つの`verse_history`オブジェクトに統合すると、D-36-1のスコープ（bui情報源の
  限定）と其の三十六の独立性方針（逆戻り検知は本文のみ）が同じデータ構造内で
  衝突しうる

`fetch_verse_chain`という行取得の共有はすでに達成済みで、それ以上の統合（出力形状の
一本化）はメリットがないというのが所見（決定ではない）。

---

## 判断が必要な点（手順2着手前）

1. **統合先は(A) RengaGeneratorの生成誘導、(B) RengaCheckerプロンプトへの注入、
   どちらか、あるいは両方か。** D-19-5解消を依頼書通りの完了条件とするなら(B)が必須。
   (A)は"死んだコードの活用"という別の価値はあるが、D-19-5の誤判定は直らない。
2. bui情報：(A)を採る場合、`build_verse_history`の`bui: []`をB層`BuiDictionary`で
   埋めるかどうか（D-36-1の範囲内での判断）。今回のスコープ外という依頼書の記載
   （5節）とも整合するよう、`bui: []`のまま接続するのか確認したい。
3. (B)を採る場合、`RengaChecker`（LLM呼び出しクラス）への変更が発生するため、
   依頼書4節の「ShikimokuChecker（A層）は純粋関数原則を維持」に加えて、C層クラス
   への変更範囲・動作確認方法（`rails runner`+`OllamaClient`差し替え）を別途
   具体化する必要がある。

以上、D-33-1に基づきここで一旦停止する。方針が確定次第、手順2（設計・実装）に進む。
