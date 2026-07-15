# 其の三十八 手順2依頼書：ShikimokuChecker実接続・RengaChecker式目判定廃止

**作成日:** 2026-07-15
**前提:** report_sono38_chousa.md / report_sono38_chousa2.md の調査完了済み
**設計判断:** D-38-1（RengaCheckerの式目判定役割をShikimokuCheckerで置換する）

---

## 0. ゲートチェック（手順1で済んでいるはずだが念のため）

```bash
git log --oneline -3
git status
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null | tail -3
```

期待値：working tree clean、88 pass / 0 fail。

---

## 1. 設計判断の記録

以下を `docs/architecture_decisions.md` に追記すること（其の三十八セクション）。

### D-38-1 RengaCheckerの式目判定役割廃止

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

### D-38-2 ng時の差し戻し（事後ラベリングから受理/却下へ）

**判断：** ShikimokuCheckerがng（violations非空）を返した場合、Renga.create!を
実行せず、ユーザー（またはメンタムさん）に差し戻す。KuValidatorの字数ng分岐と
同パターン。

**理由：** 決定論的にng判定された句を本データとして保存する理由がない。

**観測方針：** 差し戻し頻度・違反種別をログ（generation_attempts.log相当）に記録し、
自動リトライ（RengaGenerator内でのshikimoku_streak新設）の要否は
実データを観測してから判断する。

---

## 2. 実装（4ステップ、各ステップでdiff確認 → 承認後にコミット）

### ステップ2-1：build_verse_history の bui 投入

`rengas_controller.rb` の `build_verse_history`（其の三十七で一本化済み）を修正。
`bui: []` を `BuiDictionary.detect_all(text)` で埋める。

```ruby
# 変更前
{ bui: [], season: season_from_text(r["tsugeku"]), verse_type: vtype }

# 変更後
text = r["tsugeku"]
{ bui: BuiDictionary.detect_all(text),
  season: season_from_text(text),
  verse_type: vtype }
```

**注意：**
- `BuiDictionary.detect_all` が存在するか、メソッド名が正しいか確認すること。
  存在しない場合は既存のbui検出メソッド（`detect_bui` 等）の名前を使う。
  新規メソッドの作成が必要な場合は報告して停止すること。
- D-36-1厳守：C層（LLM自己申告）のbui値を混入させない。情報源はB層BuiDictionary限定。
- 前句（maeku）のbui も同様に埋めること（historyの末尾にmaekuを追加する箇所）。

### ステップ2-2：ShikimokuChecker呼び出しの新設

`rengas_controller.rb` の `RengaChecker.new([maeku, tsugeku]).check` 呼び出し箇所
（52行目付近）を、以下に置換する。

```ruby
# ShikimokuCheckerによる決定論的式目チェック
candidate = {
  bui: BuiDictionary.detect_all(tsugeku),    # ← 新生成句もB層で判定
  season: season_from_text(tsugeku),
  verse_type: next_type                       # ← 変数名は既存コードに合わせること
}
history = build_verse_history(previous_renga_id)

violations = ShikimokuChecker.all_violations(history, candidate, bui_dict: BuiDictionary)
violations += ShikimokuChecker.ichiza_violations(history, candidate)
violations += ShikimokuChecker.chotan_violations(history, candidate)

style_result = {
  "result"    => violations.empty? ? "ok" : "ng",
  "issues"    => violations.map { |v| ShikimokuChecker.describe(v) },
  "breakdown" => []
}
```

**注意：**
- `ShikimokuChecker` のメソッドがクラスメソッドかインスタンスメソッドか確認すること。
  インスタンスメソッドなら `ShikimokuChecker.new` を経由する。
  調査報告1の一覧表から判断する限りインスタンスメソッドの可能性が高い。
- `all_violations` の `bui_dict:` キーワード引数の渡し方を、
  既存テストコード（`verify_shikimoku.rb`）の呼び出し形と合わせること。
- `ShikimokuChecker.describe` はクラスメソッド（`self.describe`）であることを
  調査報告1で確認済み。

### ステップ2-3：ng時の差し戻し分岐

ステップ2-2で得た `style_result` を使い、ng時は `Renga.create!` をスキップする
分岐を追加する。既存の `KuValidator` ng分岐（`rengas_controller.rb:28-43`付近）と
同じパターンで実装すること。

```ruby
if style_result["result"] == "ng"
  # violations情報をflash/sessionに保持してviewに差し戻す
  # 「式目違反あり。再生成してください」的なメッセージと違反内容を表示
  # Renga.create! は実行しない
  # ※ generation_attempts.log への記録は既存のロギング機構に従う
else
  # 既存通り Renga.create! して保存
  @renga = Renga.create!(
    ...,
    style_check_result: style_result,
    ...
  )
end
```

**注意：**
- KuValidatorのng分岐の実装パターン（flash使用かrender使用か）を実際に確認し、
  同じ方法で実装すること。パターンが違う新方式を発明しない。
- ng時にも tsugeku の内容をログに残すこと（temp保存相当。
  将来の「同じ句を再生成しない」禁止令の材料になる）。

### ステップ2-4：RengaChecker呼び出しの削除

`rengas_controller.rb` から `RengaChecker.new(...)` の呼び出し行を削除する。
`require` や `app/services/renga_checker.rb` ファイル自体は残す
（将来の解釈コメント生成用途の余地）。

**削除確認：** `grep -rn "RengaChecker" app/` で、残っているのが
`renga_checker.rb` 自身の定義のみであることを確認すること。

---

## 3. テスト

### 既存テスト
```bash
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null | tail -5
```
88 pass / 0 fail が維持されていること。

### 動作確認（rails runner）

```ruby
# OllamaClient差し替え（既存パターン）
# 1. violations == [] のケース（ok）→ Renga.create! が実行されることを確認
# 2. violations != [] のケース（ng）→ Renga.create! がスキップされることを確認
# 3. bui情報が正しく埋まっていることを、build_verse_history の出力で確認
```

具体的なrails runnerスクリプトはステップ2-2完了後に作成すること（既存の
OllamaClient差し替えパターンを踏襲）。

---

## 4. 制約の再確認

- D-36-1：bui情報源はB層BuiDictionary確定値のみ。C層（LLM自己申告）は混入させない
- D-33-1：本依頼書が承認文書そのもの。ステップ2-1〜2-4の範囲内で進めてよい
- ShikimokuChecker（A層）のコードは変更しない
- RengaGenerator内部のstreak機構は一切触れない
- viewは3キーHash互換で無改修
- 長時間dryrunが必要な場合はtmux経由

---

## 5. やらないこと

- ng時の自動リトライ（shikimoku_streak新設）→ 観測してから判断
- 体用フラグの新規実装 → BuiDictionary既存辞書をそのまま使う
- 折跨ぎ制限 → 水無瀬版では不要（Phase 8-3設計メモの通り）
- dryrun harnessへの反映 → 本番コード優先、harness側は別セッション
- RengaGenerator#build_full_prompt への next_constraints 接続 →
  事前誘導の有効化は今回bui投入で自動的に起きる範囲に限定。
  build_full_prompt の構造変更（D-33-1対象）は今回は行わない

---

## 6. 完了条件

- [ ] architecture_decisions.md に D-38-1 / D-38-2 を追記
- [ ] build_verse_history の bui が BuiDictionary 確定値で埋まっている
- [ ] ShikimokuChecker による事後判定（kuzari+kukazo+ichiza+chotan）が動作
- [ ] ng時は Renga.create! がスキップされ、違反内容が表示される
- [ ] RengaChecker の呼び出しが controller から削除されている
- [ ] 既存テスト 88 pass / 0 fail 維持
- [ ] rails runner で ok/ng 両ケースの動作確認済み
- [ ] diff提示 → 人間承認 → コミット → push
- [ ] 其の三十八 引き継ぎドキュメント（handover）作成

---

## 7. Claude Codeへの投入文

```
docs/iraisho_sono38_step2.md に従って、ステップ2-1から順に実装してください。
各ステップでdiffを見せてから次に進んでください。

まずステップ2-1（build_verse_historyのbui投入）から着手してください。
BuiDictionary のbui検出メソッドの正確な名前を確認してから実装に入ること。
```
