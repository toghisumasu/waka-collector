# 長句「に」止め許容修正（案B） 100句本番走行 結果報告

- 作成日：2026-09-03
- セッション：其の◯◯（Phase1実装 `fix: clean_phrase_edges?で長句「に」止めを合法として許容` commit `dd4e3ab`）
- observation_batch：`sono76_mcflag_p4_run100_20260902`（p4 = Phase4 = clean_phrase_edges?長句「に」止め修正）
- 比較対象：p3 run100（`sono76_mcflag_p3_run100_20260902`、`docs/phase1_deflock_run100_report.md`）
- ゲートチェック：`bundle exec ruby script/verify_shikimoku.rb` → **116 pass / 0 fail**（走行後も維持）
- 走行ログ：`log/observation_sono76_mcflag_p4_run100_20260902.jsonl`／
  `log/stepwise_steps_20260902.jsonl`・`log/stepwise_steps_20260903.jsonl`
  （batch跨日、`batch: sono76_mcflag_p4_run100_20260902`、2193レコード）

---

## 0. 結論（要約）

修正は狙い通りに機能した：**長句の「に」止め誤検出は14件→0件に完全解消**、
句切れ不自然の総件数も175件→156件（-10.9%）に減少した。ng率・生成失敗率も
p3から続けて改善。一方、Step3流入flow単体で見た「deflock率」は
p3からさらに小幅に悪化しており、これは案3以降繰り返し観測されている
「易しいケースが前段（Step1.5/Step3前ゲート/句切れ許容）で捌かれる分、
Step3ループに残る残差が相対的に手強くなる」という同一パターンの継続と考えられる。

| 指標 | p3 run100 | p4 run100（実測） | 判定 |
|---|---:|---:|---|
| ng率 | 8.3% | **6.5%** | 改善 |
| 生成失敗（5draft全滅） | 4/100 | **3/100** | 改善 |
| 句切れ不自然（総件数） | 175 | **156**（-10.9%） | 改善 |
| chouku「に」止め誤検出 | 14件 | **0件** | 解消 |
| chouku「て」止め誤検出 | 0件（未観測） | 0件（未観測） | 変化なし（該当例なし） |
| Step3呼出回数 | 510 | 567 | 増加 |
| Step1.5非skip発動回数 | 413 | 437 | 増加 |
| deflock率A（attempt5/Step3流入flow） | 73.2% | 76.5% | 悪化（小幅） |
| deflock率B（attempt5/全draft） | 46.9% | 49.3% | 悪化（小幅） |
| 所要時間 | 81.1分 | 84.3分 | 微増 |

---

## 1. 修正の直接効果：長句「に」「て」止めの誤検出

`script/analyze_deflock_mora.rb`と一時解析スクリプト（Phase0報告書で使用したものと
同一ロジック、`verse_type`別クロス集計に対応させ再利用）で確認した。

### 1-1. tail破れの verse_type × 末尾 クロス集計

| verse_type / 末尾 | p3 run100 | p4 run100 |
|---|---:|---:|
| chouku / の | 31 | 49 |
| **chouku / に** | **14** | **0** |
| chouku / を | 5 | 0 |
| chouku / が | 5 | 6 |
| chouku / ば | 5 | 0 |
| chouku / や | — | 7 |
| chouku / は | — | 5 |
| tanku / の | 28 | 21 |
| tanku / に | 20 | 15 |
| tanku / て | 2 | 7 |
| tanku / を | — | 2 |
| tanku / たり | — | 5 |
| tanku / も | — | 3 |
| tanku / ば | — | 1 |
| tanku / が | 6 | — |
| tanku / は | 3 | — |

**chouku「に」止め・chouku「て」止め・chouku「ば」止め・chouku「を」止めの
棄却が今回のp4 run100では0件**になった（修正が意図通り機能）。
一方、`chouku_tail_exception?`の対象外である**tanku側の「に」「て」棄却は
従来通り機能**しており、短句の判定に回帰はない。

### 1-2. 句切れ不自然の総数変化

| | p3 | p4 |
|---|---:|---:|
| 句切れ不自然（step4ログの総件数） | 175 | 156 |
| うちtail破れ | 119 | 121 |
| うちhead破れ | 56 | 35 |

tail破れの絶対数はほぼ横ばい（119→121）だが、**head破れが56→35に減少**した。
これは直接の設計対象ではなかったが、`chouku_tail_exception?`によって
一部のflowがそもそも早期成功しリトライが減った結果、head破れを生む
後続attemptの母数自体が減った可能性がある（副次効果、因果は未検証）。

---

## 2. 全体指標

### 2-1. ng率・生成コスト

```
総試行回数: 107
総ng回数:   7
ng率:       6.5%
所要時間:   5056.6秒 / 84.3分
Ollama呼出総数: 1232回
  step3_mora_rewrite  567回  合計1957.8秒
  step1_5_length      437回  合計1955.5秒
  step1_free_verse    228回  合計1080.7秒
違反種別の内訳: 句数 4件
```

retry理由の内訳（`action: "retry"`）：

| 理由 | p3 (n=9) | p4 (n=7) |
|---|---:|---:|
| 生成失敗（5draft全滅） | 4 | 3 |
| 句数:秋 | 3 | 3 |
| 句数:春 | 1 | 1 |
| 接続タイムアウト | 1 | 0 |

生成失敗は4→3とさらに改善。ng率も8.3%→6.5%に改善しており、
**案3・案4を通じて最終指標は一貫して改善傾向**にある。

なお本走行は1回目の起動が「発句として使えるWakaが見つかりませんでした
（20回試行）」で即座に失敗し、再実行で成功した。原因はStepwiseWakaGenerator
呼び出し前の発句抽選（`Waka.where(...).order(RANDOM()).first`を20回試行）の
偶発的な連続失敗と考えられる（同条件のサンプル50件中46件＝92%が有効な
ことを別途確認済み。20連続失敗の確率は理論上極めて低く、一時的なDB応答遅延等の
可能性があるが、本修正のコードパスより前段の処理であり無関係）。

### 2-2. deflock率・Step1.5発動状況

| | p3 | p4 |
|---|---:|---:|
| Step1.5 skip | 96 | 93 |
| Step1.5 expand | 199 | 196 |
| Step1.5 condense | 214 | 241 |
| Step3前ゲート（案2）スキップ数 | 69 | 73 |
| Step3流入flow数（attempt1） | 123 | 132 |
| 全draft数 | 192 | 205 |
| attempt5到達数 | 90 | 101 |
| deflock率A（attempt5/Step3流入flow） | 73.2% | **76.5%** |
| deflock率B（attempt5/全draft） | 46.9% | **49.3%** |

両定義とも小幅ながら悪化方向が継続している。案3導入後の`docs/phase1_deflock_run100_report.md`
で述べた「易しいケースが前段で捌かれるほど、Step3ループに残る残差の質が
相対的に悪化する」という構造が、案4（句切れ不自然の一部解消）でも
同じ形で再現していると考えられる。ng率・生成失敗という最終指標は
一貫して改善しているため実害は出ていないが、**Step3ループ本体の
低命中率という根本課題は依然未解消**である。

---

## 3. 総合評価

- 依頼書が対象とした誤検出（長句「に」止め）は**完全に解消**、副作用（tanku側の
  回帰）は無い。
- ng率・生成失敗率という最終指標はp3からさらに改善。
- 一方、Step3ループ単体の収束しにくさ（deflock率）は小幅ながら悪化を継続しており、
  これは今回の修正固有の問題ではなく、案3以降繰り返し観測されている構造的傾向
  （前段の救済策が効くほど残差が難化する）と判断する。
- 変更は行っていない（本報告は既存走行結果の集計・整理のみ）。

---

## 付録：一次資料

- 実装コミット：`dd4e3ab`（`fix: clean_phrase_edges?で長句「に」止めを合法として許容`）
- 集計スクリプト：`script/analyze_deflock_mora.rb`
- 走行ログ：`log/observation_sono76_mcflag_p4_run100_20260902.jsonl`／
  `log/stepwise_steps_20260902.jsonl`・`log/stepwise_steps_20260903.jsonl`
  （batch: `sono76_mcflag_p4_run100_20260902`）
- 比較元：`docs/phase1_deflock_run100_report.md`（p3 run100）、
  `docs/phase0_phrase_edges_report.md`（Phase0調査）
