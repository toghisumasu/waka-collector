# 案3（Step1.5閾値整合）100句本番走行 結果報告

- 作成日：2026-09-02
- セッション：其の◯◯（Phase1実装 `fix: Step1.5閾値をStep4受理域(29-33音)に整合 (案3)` commit `1184e8f`）
- observation_batch：`sono76_mcflag_p3_run100_20260902`（p3 = Phase3 = Step1.5閾値整合）
- 比較対象：Phase1 run100（`sono76_mcflag_p1_run100_20260901`、`docs/phase0_deflock_report.md`）
- ゲートチェック：`bundle exec ruby script/verify_shikimoku.rb` → **116 pass / 0 fail**（走行後も維持）
- 走行ログ：`log/observation_sono76_mcflag_p3_run100_20260902.jsonl`／
  `log/stepwise_steps_20260902.jsonl`（`batch: sono76_mcflag_p3_run100_20260902`、2040レコード）

---

## 0. 結論（要約）

| 指標 | Phase1 run100 | 期待値 | 実測（p3 run100） | 判定 |
|---|---:|---|---:|---|
| ng率 | 11.5% | 同等以下 | **8.3%**（9/109） | 改善 |
| Step3呼出回数 | 639回 | 減少傾向 | **510回**（-20.2%） | 改善 |
| Step1.5発動回数（非skip＝実際にLLM呼出） | 132回（condense7/expand125） | 大幅増加 | **413回**（condense214/expand199） | 大幅増加（3.1倍） |
| 所要時間 | 64.6分 | 不明 | **81.1分**（+25.5%） | Step1.5増加による想定内の増加 |
| 生成失敗（5draft全滅） | 5/100 | — | **4/100** | 横ばい〜微改善 |

**「全draft deflock率」は定義によって結論が反転する**（詳細は§2）。100句本番でも
案3単独ではStep3側の二山構造・低命中率は解消しておらず、代わりにStep3に残留する
理由の内訳が変化した（too_short劇減・句切れ不自然が相対的に上昇）。これが
本報告書の後続調査（`docs/依頼書_phrase_edges_phase0.md`）の直接の動機。

---

## 1. 基本指標

### 1-1. ng率・生成コスト

`bundle exec rails runner script/observe_waka_extraction.rb 100 mcflag_p3_run100` の出力より：

```
総試行回数: 109
総ng回数:   9
ng率:       8.3%
forced_zatsu採用: 0句
観測完了（総所要 4865.6秒 / 81.1分）
Ollama呼出 総数: 1144回 / 合計4802.9秒
  step3_mora_rewrite  510回  平均3.4秒  合計1740.9秒
  step1_5_length      413回  平均4.9秒  合計2006.4秒（最大180.0秒＝1回タイムアウト）
  step1_free_verse    221回  平均4.8秒  合計1055.6秒
違反種別の内訳: 句数 4件
```

Phase1 run100（`sono76_mcflag_p1_run100_20260901`）との比較：

| | Phase1 | p3 |
|---|---:|---:|
| 総試行回数 | 113 | 109 |
| 総ng回数 | 13 | 9 |
| ng率 | 11.5% | 8.3% |
| 所要時間 | 64.6分 | 81.1分 |
| Ollama呼出総数 | — | 1144回 |

### 1-2. retry理由の内訳（`observation_*.jsonl`の`action: "retry"`）

| 理由 | Phase1 (n=13) | p3 (n=9) |
|---|---:|---:|
| 生成失敗（5draft全滅） | 5 | 4 |
| 句数:秋 | 5 | 3 |
| 句数:春 | 0 | 1 |
| 句去:七句去物 | 2 | 0 |
| 接続タイムアウト | 1 | 1 |

生成失敗（deflock由来の最終的な生成断念）は5→4とほぼ横ばい〜微改善。
「句数」（filter_pool由来の句数バランス制約）はP1と同水準。

---

## 2. Step3/Step1.5の内部挙動

`script/analyze_deflock_mora.rb sono76_mcflag_p3_run100_20260902` の実行結果より：

### 2-1. Step1.5発動状況

| direction | Phase1 (旧閾値25/50) | p3 (新閾値29/33) |
|---|---:|---:|
| skip（無補正） | 204 | 96 |
| expand（音数不足補正） | 125 | 199 |
| condense（音数超過補正） | 7 | 214 |
| 合計ログ行数 | 336 | 509 |

閾値を狭めた狙い通り、condenseが7→214に急増（33音超はごく普通に発生するため）。

### 2-2. Step3前ゲート（案2 pre_seg）スキップ率

| | Phase1 | p3 |
|---|---:|---:|
| スキップ（Step3不要） | 39 | 69 |
| Step3流入（attempt1） | 168 | 123 |
| 全draft数 | 207 | 192 |
| スキップ率 | 18.8% | **35.9%** |

Step1.5が事前に29-33へ収束させる効果でスキップ率がほぼ倍増。

### 2-3. 「全draft deflock率」— 定義による結論の相違

| 定義 | Phase1 | p3 | 判定 |
|---|---:|---:|---|
| A: attempt5到達数 ÷ **Step3流入flow数**（`docs/phase0_deflock_report.md`の原定義） | 104/168 = **61.9%** | 90/123 = **73.2%** | 悪化 |
| B: attempt5到達数 ÷ **全draft数**（skip含む） | 104/207 = 50.2%（参考値） | 90/192 = **46.9%** | 改善 |

同じ生データでも分母の取り方で結論が反転する。**Step1.5が積極的に発動したことで
「一度もStep3に入らず即成功するflow」（スキップ）が増えた一方、Step3に入らざるを
得なかった残りのflowは以前より収束しにくくなっている**（定義Aで悪化として表れる）。
attempt1時点のStep3流入flowの平均moraはPhase1の33.9からp3では36.6へ上昇し、
Step3単体の1回目成功率も16.7%→11.4%に低下している。

最終的な生成成功率（§1-2の生成失敗4/100）は横ばい〜微改善のため、
現時点で実害は出ていないが、**「案3だけでStep3側の二山構造を解消する」という
仮説は部分的にしか成立していない**。

### 2-4. Step3呼出理由（feedback_issue）の内訳の変化

| 理由 | Phase0時点（旧閾値run100） | p3 run100 |
|---|---:|---:|
| too_short（不足） | 35.0% | 大幅減（Step1.5が吸収） |
| too_long（超過） | 31.4% | 35.9% |
| 句切れ不自然（境界の語破れ） | 27.4% | **37.0%（上昇）** |
| 区切り不一致 | 6.2% | 10.6% |

too_shortがStep1.5の閾値整合で吸収された一方、**句切れ不自然の相対比率が上昇**した。
この現象の原因調査（Step1.5の副作用の疑い）が`docs/依頼書_phrase_edges_phase0.md`の主題。

---

## 3. 総合評価

- ng率・生成失敗率という最終指標は改善。Step3呼出回数というコスト面も改善。
- 一方「全draft deflock率」は定義に依存して結論が変わり、少なくとも
  Step3流入flow単体で見ると収束しにくさはむしろ悪化している。
- 句切れ不自然の比率上昇はStep1.5の副作用の可能性があり、次調査で検証する。
- 変更は行っていない（本報告は既存走行結果の集計・整理のみ）。

---

## 付録：一次資料

- 実装コミット：`1184e8f`（`fix: Step1.5閾値をStep4受理域(29-33音)に整合 (案3)`）
- 集計スクリプト：`script/analyze_deflock_mora.rb`
- 走行ログ：`log/observation_sono76_mcflag_p3_run100_20260902.jsonl`／
  `log/observation_sono76_calls_mcflag_p3_run100_20260902.jsonl`／
  `log/stepwise_steps_20260902.jsonl`（batch: `sono76_mcflag_p3_run100_20260902`）
- 比較元：`docs/phase0_deflock_report.md`（Phase0調査、`sono76_mcflag_p1_run100_20260901`）
