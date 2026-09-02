# 依頼書 二山・deflock Phase 0 調査

**担当**: クロコさん（Claude Code）
**起票**: Claude.ai（其の◯◯）
**種別**: Phase 0（読み取り専用・変更なし）
**ベースコミット**: 70b9b3a
**保存先**: `docs/依頼書_deflock_phase0.md`

---

## 背景

Phase 1 run100（observation_batch: sono76_mcflag_p1_run100_20260901）で
ng率は41.5%→11.5%に改善したが、以下の構造的問題が残存している。

| 指標 | 値 |
|------|-----|
| deflock率（rewrite_attempt=5到達） | 61.9% |
| Step3単体での31音命中率 | 3% |
| mora分布の高位集中（34-41音） | 57% |

候補対策:
- **案6**: Step3プロンプトの圧縮バイアス是正（文言修正）
- **案3**: Step1.5↔Step4閾値整合（デッドゾーン解消）
- **案4**: 知識蓄積型2段プロンプト（qwen3:30b-a3b実験知見の応用）

本Phase 0では「枯れてから足す」原則に従い、
実装前に現状を定量的に把握する。

---

## やること

### §0 事前確認（ゲートチェック）

```bash
bundle exec ruby script/verify_shikimoku.rb
# → 116 pass / 0 fail を確認してから作業開始
```

---

### §1 コード読み取り（stepwise_waka_generator.rb）

以下の4点を調査し、成果物に全文・数値を記録する。

#### §1-1 Step3プロンプトの現文言

`rewrite_with_step3` メソッド内のprompt/feedback生成部分（案5実装後）を抽出。
特に以下を確認する:

- 「圧縮」「短く」「音を減らせ」等の指示語とその強度・条件
- 方向性フィードバック（too_long/too_short別の文言）
- deflock判定の条件と発動タイミング

#### §1-2 温度スケジュール

`rewrite_attempt` 毎の temperature 値と変化量を表形式で整理する。

#### §1-3 Step1.5のスキップ条件

「free_textが既に29-33音ならStep3をスキップ」（案2）の
正確な実装を確認する。`tolerance:` 引数（案1）も含めて境界値を整理する。

#### §1-4 Step4の抽出境界

`extract_mora_segment` での最終抽出条件（31音±1）を確認する。
Step1.5スキップ条件との数値的連続性を検証する。

---

### §2 観測データ集計

`script/analyze_deflock_mora.rb` を新規作成して実行する。
**DBへの書き込みは禁止。SELECTのみ。**

```ruby
# 集計対象: observation_batch = 'sono76_mcflag_p1_run100_20260901'
#
# 集計項目:
# 1. rewrite_attempt別のmora分布
#    （attempt 1〜5それぞれで、Step3入力時のfree_text mora数の分布）
# 2. deflock句（rewrite_attempt=5到達）の最終出力mora分布
# 3. Step3呼出理由（too_long/too_short）の内訳と件数
# 4. Step3スキップ（案2発動）句のmora分布
#    （スキップが観測ログに記録されていない場合はその旨を記録）
```

※ `SeasonHintLogger` が `observe_waka_extraction.rb` 経由では
　 includeされていない計装不足は既知。
　 取得できない項目はその旨を明記して集計をスキップする。

---

### §3 案の実現性評価

§1・§2の調査結果を元に、各案を以下の観点で評価する。

| 案 | 評価観点 |
|----|---------|
| 案6 | プロンプトで「縮める」指示が支配的か「書き直す」指示が支配的か。高域偏重（34-41音）の原因文言を特定できるか |
| 案3 | Step1.5スキップ条件(29-33)とStep4境界(30-32)の間にデッドゾーンが数値的に存在するか |
| 案4 | 既存Step0（前句見立て言語化）との差分を整理。2段階構成にした場合の追加Ollama呼出コストを試算（概算でよい） |

推奨実装順序を理由とともに提示すること。

---

## やらないこと

- `app/` 配下の変更（D-33-1）
- DBへの書き込み・新規observation_batch作成
- 100句走行
- verify_shikimoku.rb 以外のテスト変更

---

## 成果物

`docs/phase0_deflock_report.md` に以下を記録してコミットする:

```
- §1-1: Step3プロンプト現文言（全文）
- §1-2: temperatureスケジュール表
- §1-3: Step1.5スキップ条件の境界値
- §1-4: Step4抽出条件とStep1.5との連続性評価
- §2: mora分布集計結果（表形式）
- §3: 案6/案3/案4の実現性評価と推奨実装順序
```

※ 変更なしが正当な結論の場合はその旨を明記して終了する。

---

## 受入条件

- `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- DBへの書き込みなし
- `script/analyze_deflock_mora.rb` は実行後もリポジトリに残す
- `docs/phase0_deflock_report.md` をコミット（1タスク1コミット）
- 本依頼書自体も `docs/依頼書_deflock_phase0.md` としてコミット

---

## 承認ゲート（Claude.ai側）

Phase 0完了後、`docs/phase0_deflock_report.md` の内容を
Claude.aiスレッドに貼り付けて確認を受けること。
実装（Phase 1）はClaude.aiの承認後にのみ着手する。
