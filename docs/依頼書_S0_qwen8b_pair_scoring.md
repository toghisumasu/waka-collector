# 依頼書 S-0：水無瀬三吟 付合ペアの qwen3:8b スコアリング（基礎データ収集）

> フェーズ番号「S-0」は仮称。既存の体系（距離-Phase2 等）に合わせて付け替えてよい。

## 1. 目的

水無瀬三吟（1488）の付合ペア（前句→付句、99ペア）を qwen3:8b（no-think）で採点し、基礎データを取る。あわせて、Nobuson が手でラベル付けするための盲検シートを作る。

後続の S-1（modernbert-ja-310m-jev による同一採点）と S-2（手ラベルとの相関確認）の土台になる。本依頼では **判定・閾値決定・本番配線は一切行わない**。

## 2. §0 事前資料配置確認（着手前に必ず実施）

以下の存在と内容を確認し、結果を報告すること。無いものは推測で補わず、その旨を報告して停止する。

| 資料 | 確認内容 |
|---|---|
| `script/measure_minase_distance.rb` | 99ペアの読み込み方式（DB or ファイル）、ペア番号の振り方 |
| `script/measure_bui_distance.rb` | 計算コアの切り出し状況 |
| `tmp/minase_bui_distance_report.csv` | カラム構成、ペア番号の規則（S-0 の出力と結合できるか） |
| `app/services/ollama_client.rb` | `think: false`・`temperature`・`num_predict` を渡せるか。**渡せない場合も app/ は変更しない**（下記参照） |
| Ollama（Mac mini） | `ollama list` に qwen3:8b があること、起動していること |

## 3. やること

### 3-1. 調査結果の提示（承認ゲート①）

§0 の結果と、下記 3-2 のプロンプト最終案・スクリプト構成案を提示して **一度停止**。Nobuson の明示的承認後に実装へ進む。
（測定器の設計そのものが結果を左右するため、プロンプト文面も承認対象とする）

### 3-2. 採点スクリプトの新規作成

`script/score_minase_pairs_qwen8b.rb`（新規・読み取り専用）

- 実行は `bin/rails runner` 経由（Rails.root 使用のため）
- モデルは **`WAKA_OLLAMA_MODEL=qwen3:8b` を明示指定**して実行。スクリプト側でもモデル名を必須引数扱いにし、未指定なら異常終了させる
- OllamaClient が `think: false` / `temperature` / `num_predict` を渡せない場合は、**スクリプト内に薄い HTTP 呼び出しを持つ**（app/ は変更しない）
- 各呼び出しは独立した単発リクエスト（文脈を持ち越さない）
- `think: false` は API パラメータで渡す（プロンプトへの `/no_think` は無効）
- プロンプト内に `%` がある場合は `%%` にエスケープ
- **パラメータ**：`temperature: 0.3`、`num_predict: 60`、ペアごとに **3試行**。3試行の分散を見るのが目的なので temperature 0 にはしない
- **盲検**：プロンプトに渡すのは前句・付句の本文のみ。折・季・bui 等の辞書由来情報、および「近付／遠付」等の型のヒントは一切渡さない

#### プロンプト案（承認ゲートで最終化）

```
あなたは連歌の付合を評価する。次の前句と付句を読み、3つの軸で「離れ」を1〜5の整数で評価せよ。
1 = ほぼ同じ・非常に近い、5 = まったく異なる・非常に遠い。

- season_gap: 季節感の離れ
- material_gap: 句材（題材）の離れ
- scene_gap: 情景の離れ

JSONのみを出力せよ。説明は不要。
{"season_gap": n, "material_gap": n, "scene_gap": n}

前句：{maeku}
付句：{tsukeku}
```

- 軸名を `vocab_gap` にしない。距離-Phase0 で語彙非重複率がほぼ全ペア 1.0 と判明済みで、語の重なりを測る軸は天井に張り付く。ここで測るのは意味としての句材の離れ

#### 出力

1. `tmp/minase_qwen8b_score_raw.csv`（試行単位）
   - `pair_no, maeku, tsukeku, trial, season_gap, material_gap, scene_gap, parse_ok, raw_output`
   - ヘッダーコメント行に **モデル名・temperature・num_predict・think 設定・実行コマンド・実行日時** を記録（過去に run5 のモデル名がログから失われた教訓）
   - JSON パース失敗は1回だけ再試行。それでも失敗なら `parse_ok=false` で記録し、除外せず残す
2. `tmp/minase_qwen8b_score_summary.csv`（ペア単位）
   - 各軸の中央値・最小・最大（3試行）
   - `tmp/minase_bui_distance_report.csv` とペア番号で結合した bui 距離
   - 3試行で軸のいずれかが2以上ぶれたペアには `unstable=true`

### 3-3. 手ラベル用の盲検シート

`tmp/minase_label_sheet.csv`（30ペア）

- 折ごとに3〜4ペアを抽出。季移りの有無で層別する
- 乱数シードは固定し、シードと抽出条件をヘッダーコメントに記録
- カラム：`pair_no, maeku, tsukeku, label（空欄）, memo（空欄）`
- **スコア・bui 距離は載せない**（Nobuson の判定を 8b に引きずらせないため）

### 3-4. 記述統計（判断はしない）

以下を標準出力に出し、報告に貼る。解釈・閾値の提案はしない。

- 各軸の値の分布（1〜5 の度数）。中央寄りへの偏りや天井・床効果の有無
- `unstable` ペアの件数と一覧
- 各軸中央値と bui 距離の Spearman 相関（参考値）
- parse 失敗率

## 4. やらないこと

- `app/` 配下の変更（ollama_client.rb を含む）
- DB への書き込み・migration
- ShikimokuChecker・BuiDictionary・辞書 yml の変更
- modernbert-ja-310m-jev の実行（S-1 で別依頼）
- 採点結果に基づく閾値の決定、生成・式目チェックへの配線
- 8b スコアを「正解」として扱う記述（手ラベルとの相関は S-2 で見る）

## 5. 不変条件

- ゲートチェック `bundle exec ruby script/verify_shikimoku.rb` が着手前後で同じ結果（最新実績：121 pass / 0 fail。着手前に現在値を確認して報告）
- `git diff --stat` に `app/` が現れない
- 水無瀬三吟のペア数・ペア番号の規則が既存の距離計測と一致する

## 6. 実行の目安

99ペア × 3試行 = 297呼び出し。1呼び出し約 0.5〜1 秒として 5〜10 分程度。tmux 不要だが、`nohup` で実行しログを `tmp/` に残す。途中再開機能は持たせない（短時間で終わるため）。中断時は既存出力を枝番付きで退避してから最初からやり直す。

## 7. 受入基準

| ID | 内容 |
|---|---|
| RC-GATE | ゲートチェックが着手前と同じ pass 数・0 fail |
| RC-1 | `ruby -c script/score_minase_pairs_qwen8b.rb` が RC=0 |
| RC-2 | `minase_qwen8b_score_raw.csv` が 297 行（ヘッダー・コメント行を除く）。不足なら理由を報告 |
| RC-3 | raw CSV のヘッダーコメントにモデル名（qwen3:8b）・temperature・実行コマンドが記録されている |
| RC-4 | `minase_qwen8b_score_summary.csv` が 99 行で、bui 距離が全行結合されている |
| RC-5 | `minase_label_sheet.csv` が 30 行で、スコア列・bui 距離列を含まない |
| RC-6 | `git diff --stat` に `app/` が含まれない |
| RC-7 | 記述統計（3-4）が報告に含まれている |
| RC-COMMIT | `git log --oneline -1` でコミットハッシュを確認 |
| RC-PUSH | `git push origin HEAD` の完了をリモート側で確認（`git ls-remote` 等でハッシュ一致） |

## 8. コミット方針

- 1タスク = 1コミットで分離：①本依頼書のドキュメントコミット ②スクリプト実装コミット
- `tmp/` 配下の成果物は、既存の `tmp/minase_bui_distance_report.csv` の git 上の扱い（追跡有無）に合わせる。判断に迷ったらコミットせず報告

## 9. 報告フォーマット

1. §0 の確認結果（表）
2. プロンプト最終案・スクリプト構成案（承認ゲート①で提示）
3. 実走後：RC 一覧（RC-GATE〜RC-PUSH）と記述統計
4. 想定外の挙動（parse 失敗の傾向、特定ペアでの極端なぶれ等）
5. 未解決事項

## 10. 後続フェーズ（本依頼の範囲外）

- **S-1**：modernbert-ja-310m-jev で同じ99ペアを採点（Jev は数値閾値が苦手なので、スコア化の方式を別途設計）
- **S-2**：Nobuson の手ラベル30ペアと、8b・Jev・bui 距離の一致度を確認
- 相関が確認できた軸だけを、4（輪廻・意味的な類似）の判定補助として設計に採用する
