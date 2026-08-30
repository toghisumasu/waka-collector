# 依頼書：must_continue／must_switch強化 Phase 0（計装追加＋原因調査）

## §0 参照ドキュメント配置確認

- 本依頼書：`docs/依頼書_must_continue強化_phase0.md` として保存してください（作業前にパス確認）
- 参照ログ・調査：`docs/investigation_step3_mora_phase0.md`（commit 76f3e93、100句本番走行結果まで）
- 参照コミット：`76f3e93`（Step3改善第一弾クローズ、origin/mainにpush済み）
- 対象範囲：`:waka_extraction` 戦略の観測経路（`script/observe_waka_extraction.rb`）が中心。
  `rengas_controller.rb`（本番Web経路）は既にSeasonHintLoggerを持つため今回の追加対象外

## §1 背景

Step3改善第一弾の100句本番走行で、残存ng(41.5%)の92%が`must_continue`（季節継続）・
`must_switch`（季節転換）関連の局面で発生していることが定量確認された。

| 事象 | 件数 |
|---|---|
| 句数：秋（must_continue関連） | 26件 |
| 句数：春（must_continue関連） | 10件 |
| forced_zatsuエスカレーション | 5句、うち4句が最終的にモーラngの雑句で埋まる＝季節進行未達成 |
| 300秒超アウトライア | 5句、全て季節境界のretry枯渇局面 |

秋セグメント冒頭（季を切り替えて入る／3句続ける局面）で`ShikimokuChecker`の`句数:秋`が
繰り返し発火しretryループに陥るパターンが確認されている。

**既知の構造的問題（sono84調査で確定済み）**：
`renga_generator.rb`は`build_full_prompt`到達前にearly-returnし、`StepwiseWakaGenerator`は
独自の`directive_lines`分岐を持つため、`must_continue`分岐自体が存在しない。
つまり`:waka_extraction`戦略では季節継続・転換の指示がLLMに一度も渡っていない可能性が高い。

**観測側の計装不足**：`SeasonHintLogger`（D-52-1）は`rengas_controller.rb`にしかincludeされておらず、
`observe_waka_extraction.rb`経由の走行では`must_switch`／`must_continue`の発火フラグ自体がログに
残らない。このため、上記の「句数：秋・春」がどのタイミングで・どんな季ヒントの状態で
発生しているのか、現状のログからは追跡できない。

## §2 実施内容（2段階、まず計装のみ・低リスク）

### Step A：観測スクリプト経路への季ヒント計装追加

- `SeasonHintLogger`相当のログ出力を、`observe_waka_extraction.rb`が使う生成経路
  （`StepwiseWakaGenerator`または`RengaGenerator`の該当箇所）に追加する
- 記録すべき内容：各verse生成時点での`must_continue`／`must_switch`フラグの値、
  現在の季節ラベル、（フラグがtrueの場合）対象の季節・理由
- 既存の`development.log`の`[SeasonHint]`形式に準拠し、可能なら`log/stepwise_steps_*.jsonl`
  等の構造化ログにも同等の情報をフィールド追加する形で残す
- **この時点ではmust_continue自体のロジック・プロンプトは変更しない**（観測のみ）

### Step B：既存ログの再解析（小規模）

- Step A実装後、10句程度の小規模再走行（smoke test）を行い、計装が意図通り機能しているか確認
- 秋セグメント冒頭でのretryループ発生時に、`must_continue`／`must_switch`フラグが
  実際にどう推移しているかを確認する
- `renga_generator.rb`のearly-returnと`StepwiseWakaGenerator`の`directive_lines`分岐について、
  実際にmust_continue相当の情報がどこかに（別の形で）伝わっている可能性がないか、
  コードを再確認する（sono84調査時点の結論の再確認）

## §3 やってはいけないこと

- `must_continue`／`must_switch`のロジック自体の実装変更（今回は計装・調査のみ）
- Step3・Step4・ガード関連のコード変更（前回スコープ、今回は対象外）
- `rengas_controller.rb`（本番Web経路）への変更（既にSeasonHintLoggerを持つため触らない）
- 保護ファイル（`app/data/*.yml`, `dict/user_entries.csv`）の変更
- `:direct`戦略のコードパスへの影響

## §4 成果物

`docs/investigation_step3_mora_phase0.md` とは別に、新規ドキュメント
`docs/investigation_must_continue_phase0.md` を作成し、以下を記載：

- 計装追加箇所のdiff（実装前に提示・承認）
- 10句smoke testでの計装ログ実例（must_continue/must_switchフラグの推移が分かる形）
- 秋セグメント冒頭でのretryループの実態（フラグは立っていたが指示が渡っていなかったのか、
  そもそもフラグ自体が立っていなかったのか）
- 5d4e9a6（must_continue時季節継続指示、:direct戦略向け実装）を`:waka_extraction`側にも
  適用する場合の実装方針案（複数案、実装はしない）

## §5 完了条件（RC=0）

- 計装のdiffが実装前に人間に提示され、承認を得ていること
- `bundle exec ruby script/verify_shikimoku.rb` が116 pass / 0 fail
- 10句smoke testが実行され、計装ログの実例が `docs/investigation_must_continue_phase0.md` に記載されている
- git status がクリーン
- `:direct`戦略・`rengas_controller.rb`に影響がないこと

---
※今回は計装＋原因調査までとし、修正の実装は次回別依頼書とする。
※案6（Step3圧縮バイアス是正）・案3（Step1.5↔Step4閾値整合）・案4（知識蓄積型2段プロンプト）は
　must_continue強化の後、二山・deflock対策として別途着手予定（温存中）。
