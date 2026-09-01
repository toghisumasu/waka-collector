# 依頼書：Phase1 run100 ログ回収・集計・報告

## §0 参照ドキュメント配置確認

- 本依頼書：`docs/依頼書_phase1_run100_集計報告.md` として保存してください（作業前にパス確認）
- 参照実装：`docs/investigation_must_continue_phase0.md`（commit f0810d9）
- observation_batch：`sono76_mcflag_p1_run100_20260901`
- ログファイル：
  - `log/observation_sono76_mcflag_p1_run100_20260901.jsonl`
  - `log/observation_sono76_calls_mcflag_p1_run100_20260901.jsonl`

## §1 確認済みの速報値

コンソール出力から以下が確認済み：

| 指標 | Phase1前 run100 | Phase1 run100 |
|---|---|---|
| ng率 | 41.5% | **11.5%** |
| forced_zatsu | 5句 | **0句** |
| 総Ollama呼出 | 1824回 | 995回(-45%) |
| 所要時間 | 111.4分 | **64.6分(-42%)** |
| 1句あたり平均レイテンシ | 66.9秒 | 38.8秒(-42%) |
| 300秒超過 | 5句 | 1句(v75) |
| ng内訳（速報） | 句数:36件・句去:3件 | 句数:5件・句去:2件（残り6件未確認） |
| タイムアウト失敗 | 0回 | 1回（v75、Ollama接続180秒、全体影響軽微） |

## §2 集計依頼内容

以下の4項目を `docs/investigation_must_continue_phase0.md` の末尾
「Phase1 100句本番走行結果」セクションに追記してください。

### 2-1. ng率・内訳の詳細

- 総試行回数・総ng回数・ng率を確認
- ng内訳を「must_continue起因（句数:季節）」「句去」「Step3 deflock」「その他」に分類
  - 速報では句数:5件・句去:2件、残り6件の内訳が未確認
- forced_zatsu詳細（0句の確認・モーラng許容の有無）

### 2-2. 経路1（幻の季セグメント）の再発有無

- `action:"season_hint"` 計装ログで幻の季セグメント発生件数を集計
- Phase1前 run100ではforced_zatsu 5句中3句が幻の季起因だった → 今回0句に改善した原因を確認
- `seed_season` フィールドから雑局面でのseed季節分布の実測値を集計
  （ZATSU_SEED_BIAS=0.75の妥当性評価）

### 2-3. 経路2（案Fの本番発火）の確認

- `shift_window_to_kigo` が実際に発火した件数を集計
  （Phase1 smokeでは0件、100句規模で初めて当たる見込みだった）
- 発火時に季語が窓に収まったか・モーラ精度に副作用がなかったか確認

### 2-4. レイテンシ・呼出量の詳細

- step3_mora_rewrite呼出回数をPhase1前 run100（1215回）と比較
- deflock発生率（rewrite_attempt5到達率）をPhase1前 run100（74%）と比較
- v75のタイムアウト詳細（Ollama接続180秒 RuntimeError）の原因を簡単に確認
  （Ollama側の一時的な問題か、構造的な問題か）

## §3 やってはいけないこと

- コード修正（今回は集計・報告のみ）
- observation_batchレコードの削除（分析完了後に別途判断する）
- ZATSU_SEED_BIAS値の変更（観測後に別途判断する）

## §4 成果物

`docs/investigation_must_continue_phase0.md` の末尾に「Phase1 100句本番走行結果」セクションを追記：
- §2の4項目すべての集計結果
- Phase1前 run100・Phase1 smoke・Phase1 run100 の3列比較表（最終版）
- 案C・案F・案Aそれぞれの実効性評価
- 次の改善候補（ZATSU_SEED_BIAS調整・season_from_text改善・二山対策）の優先順位に関する所感

コミットはドキュメントのみ（実装変更なし）。

## §5 完了条件（RC=0）

- `docs/investigation_must_continue_phase0.md` に結果セクションが追記されている
- `bundle exec ruby script/verify_shikimoku.rb` が引き続き116 pass / 0 fail
- git status がクリーン（ドキュメント追記のみのコミット）
