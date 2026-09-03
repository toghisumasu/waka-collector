# 依頼書 :waka_extraction → :direct 切り替え検討 Phase 0

**担当**: クロコさん（Claude Code）
**起票**: Claude.ai（其の◯◯）
**種別**: Phase 0（読み取り専用・変更なし）
**ベースコミット**: 8cdc80d（p6 run100報告書コミット後）

---

## 背景と問い

`:waka_extraction`（StepwiseWakaGenerator）は現在Mac miniのみで検証中で、
本番Web（`:direct` / RengaGenerator）への切り替えは未実施。

`:waka_extraction`の現時点の達成値:
- ng率 7.4%（Phase1起点11.5%から改善）
- forced_zatsu 0句（完全解消）

切り替えの判断にあたり、以下が未確認：
1. `:direct`の現行実装に、`:waka_extraction`側の改善がどの程度反映されているか
2. 切り替えた場合のWeb UXへの影響（応答時間・エラー処理）
3. 切り替え vs バックポートのコスト差

---

## やること

### §0 事前確認

```bash
bundle exec ruby script/verify_shikimoku.rb
# → 116 pass / 0 fail を確認
```

---

### §1 :direct（RengaGenerator）の現行実装確認

`app/services/renga_generator.rb` を読み、以下を記録する：

#### §1-1 :directに反映済みの改善

`:waka_extraction`側で実施した改善のうち、`:direct`にも実装済みのものを特定する。

確認対象:
- 案A（`directive_lines`への`continue_line/switch_line`追加、commit `5d4e9a6`）
- 案C（`ZATSU_SEED_BIAS`）
- 案F（`shift_window_to_kigo`）
- その他、直近セッションでのバックポート実績

#### §1-2 :directに未反映の改善

`:waka_extraction`専用で`:direct`に移植されていない改善をリストアップする。

確認対象（少なくとも以下が予想される）:
- Step1.5（`adjust_free_verse_length`、閾値29/33への変更）
- `clean_phrase_edges?`の長句「に」止め許容（commit `dd4e3ab`）
- Step3プロンプト受理域明示（案6、commit `9cdda76`）
- `boundary_index_near`のtanku最低mora検証（commit `b68ffbf`）
- `WakaPersona`（3ペルソナ）

#### §1-3 :directの生成フロー

`:direct`の生成フローを図示（テキスト形式）し、
`:waka_extraction`の多段パイプライン（Step0→Step1→Step1.5→Step3→Step4）と
どこが構造的に異なるかを明記する。

---

### §2 切り替えコストの試算

#### §2-1 「完全切り替え」のコスト

本番WebのデフォルトをRengaGeneratorからStepwiseWakaGeneratorに変える場合：

- Webコントローラ側の変更点（`strategy`パラメータの扱い等）
- エラーハンドリングの差異（タイムアウト・ng時の動作）
- `:waka_extraction`の処理時間（実測平均81.1分/100句=約49秒/句）が
  Web UXとして許容できる応答時間か（`:direct`の実測値と比較）

#### §2-2 「バックポート」のコスト

未反映の改善を`:direct`側に移植する場合：
- 移植対象の優先度（効果の大きいものから）
- 移植の技術的な難易度（Step1.5のような多段構造をRengaGeneratorに入れられるか）

#### §2-3 「並走」の可否

`:direct`と`:waka_extraction`を並走させてA/B比較する場合：
- 現行コードでstrategy切り替えが動的にできるか
- 並走に必要な追加実装の有無

---

### §3 推奨方針

§1・§2の結果を踏まえ、以下の3択で推奨を提示する：

| 選択肢 | 内容 |
|--------|------|
| A | 完全切り替え（:directを:waka_extractionに置き換え） |
| B | バックポート（主要改善を:directに移植） |
| C | 並走・段階的移行 |

推奨する選択肢とその理由を明記すること。

---

## やらないこと

- `app/`配下の変更（D-33-1）
- 本番への切り替え作業
- DBへの書き込み
- 走行

---

## 成果物

`docs/phase0_strategy_switch_report.md` に以下を記録してコミットする：

```
- §1-1: :directに反映済みの改善リスト
- §1-2: :directに未反映の改善リスト
- §1-3: :directの生成フロー図（テキスト）
- §2-1: 完全切り替えのコスト・UXリスク
- §2-2: バックポートのコスト
- §2-3: 並走の可否
- §3: 推奨方針（A/B/Cいずれか、理由付き）
```

---

## 受入条件

- `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- DBへの書き込みなし
- `docs/phase0_strategy_switch_report.md` をコミット（1タスク1コミット）
- 本依頼書も `docs/依頼書_strategy_switch_phase0.md` としてコミット

---

## 承認ゲート

Phase 0完了後、`docs/phase0_strategy_switch_report.md` の内容を
Claude.aiスレッドに貼り付けて確認を受けること。
切り替え実装はClaude.aiの承認後にのみ着手する。

---

## 参照資料

- `docs/waka-collector_handover_v2.md`（A/B判断の経緯・既知課題）
- `app/services/renga_generator.rb`（:direct実装）
- `app/services/stepwise_waka_generator.rb`（:waka_extraction実装）
- commit `5d4e9a6`（:directへの案A移植実績）
- p6 run100報告書（:waka_extractionの現達成値）
