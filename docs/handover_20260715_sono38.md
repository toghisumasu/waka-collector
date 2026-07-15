# waka-collector 其の三十八 引き継ぎ

HEAD: f293245 / テスト: 88 pass / 0 fail
作業日: 2026-07-15

## 完了事項

- D-38-1: RengaChecker（LLMベース）の式目判定をShikimokuChecker（Ruby決定論的判定）に置換
  - rengas_controller.rb の RengaChecker.new([maeku, tsugeku]).check を削除
  - ShikimokuChecker の all_violations + ichiza_violations + chotan_violations で統合判定
  - RengaCheckerは呼び出し元のみ削除、ファイルは温存（将来の解釈コメント生成用）
- D-38-2: ng時の差し戻し（KuValidatorのng分岐と同パターン）
  - violations非空の場合、Renga.create!をスキップしflash.now[:alert]で違反内容を表示
  - ng時のtsugeku・issuesはRails.loggerに記録
- D-38-3: 文章・文節の分析にはMeCabを標準とする原則を制定
- BuiDictionary#detect_all(text, nm) を新設（MeCab形態素ベースのbui集合検出）
- build_verse_historyのbui情報をBuiDictionary確定値（B層）で投入（D-36-1準拠）

## 設計判断の経緯（重要）

- 調査報告（report_sono38_chousa.md）で判明：ShikimokuCheckerはproductionで一度も
  呼ばれていなかった。D-19-5の当事者はRengaChecker（LLM）だった
- 追加調査（report_sono38_chousa2.md）で判明：RengaCheckerは「事後ラベリング」に
  過ぎず、ng判定しても保存を止めない設計だった。リトライにも使われていなかった
- この2つの発見により、当初の「build_verse_historyをShikimokuCheckerに接続する」
  案から、「RengaCheckerの式目判定役割を廃止しShikimokuCheckerで置換する」案に
  設計を変更した
- bui情報の投入（当初スコープ外）も今回に繰り入れた。理由：句去判定にbui情報が
  必須であり、bui: []のままでは句去チェックが機能しないため

## 既知の制限（新規の回帰ではない）

- 辞書内の複合語キー「行く水」はMeCabが分割するため検出漏れ（D-22-2と同種、温存）
- bui: nilのひらがな語（やしろ等）はBuiDictionary未登録のため検出されない（D-22-2）
- 体用フラグ未実装のため、句去判定は体用の区別なし（スコープ外として温存）

## 其の三十九への最優先

- dryrunによるng差し戻し頻度・違反種別の観測
  → メンタムさんがどの種類の式目違反をどのくらい出すかを把握する
  → 自動リトライ（shikimoku_streak新設）の要否を実データで判断する
- next_constraintsによる事前誘導の有効性評価
  → build_verse_historyのbui投入により、forbidden_buiが正しく算出される状態に
     なったはずだが、実際にRengaGeneratorのfilter_pool/kigo_hint/build_full_prompt
     でforbidden_buiが使われているかを確認する
  → 使われていない場合はnext_constraintsの接続（build_full_promptへの注入）が
     次の実装対象になる

## ゲート（次回セッション冒頭）

```bash
git log --oneline -5
git status
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null | tail -5
```

期待値：HEAD f293245、88 pass / 0 fail
