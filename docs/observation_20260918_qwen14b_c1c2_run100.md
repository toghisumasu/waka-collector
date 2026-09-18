# RengaGenerator直接観測：C-1/C-2適用後100句run（qwen3:14b）

- 実行日: 2026-09-17 23:41 〜 2026-09-18 01:58（所要時間 約2時間17分）
- 対象実装: 依頼書C適用後（commit `7cc509c` C-1 must_switch時絶対禁止ブロック移植、commit `4fd985c` C-2 build_full_promptへexample本文展開復活）
- モデル: qwen3:14b
- 実行方式: `RengaGenerator :direct`戦略、`script/observe_renga_generator.rb`（DB書き込みなし・インメモリでRengaGenerationService相当の呼び出しパターンを再現、ShikimokuChecker post-hoc検証）
- 実行コマンド: `WAKA_OLLAMA_MODEL=qwen3:14b OLLAMA_URL=http://100.71.107.6:11434 bin/rails runner script/observe_renga_generator.rb`
- ログ: `log/observe_rg_20260917.log`（stderr: `log/observe_rg_err.log`、空＝例外なし）※gitignore対象・非コミット

## 結果

- **100句完走、FORCED/VIOLATION 0件（NG率0%）**
- 生成失敗（空句）0件
- 長短交互: 100句すべて正常維持（連続同型なし）
- 季節分布: 春34 / 秋30 / 雑29 / 冬7
- 検出語彙（bui辞書ヒット、18句）: 月4・萩3・柳3・夢3・時雨2・薄1・梅1・東風1
- 七句去物対象語（月・夢・柳・萩）の再出現間隔は最短でも10句以上でクリア

## 過去実績との比較

| run | ng率 | 備考 |
|---|---|---|
| [[sono83_status]]（前句エコー修正後） | 16.8% | 句去18→4件 |
| [[sono85_phase1_run100]]（must_continue強化Phase1） | 11.5% | forced_zatsu 5→0句 |
| 本run（C-1/C-2適用後、qwen3:14b） | **0%** | FORCED/VIOLATION 0件 |

過去の直接観測結果と比較して大幅に良好な結果だった。ただし本runのみでは、C-1/C-2の効果によるものか、モデル（qwen3:8b→14b）の影響かは切り分けできていない（同条件での比較run未実施）。

## 注意点

- `observe_renga_generator.rb`はShikimoku違反時にMAX_RETRY=5で内部再試行する設計のため、ログの「OK」は最終的に式目を通過した句のみを表す。初回試行時点での違反有無はログから分からない（本runは生成失敗ログも0件だったため、大きな再試行の苦戦自体は起きていないと見られる）。
- ログファイルはRails内部の`File.open(...,"a")`直接書き込みと`tee`の両方が同じファイルに書き込むため1句につき2行ずつ重複する。稀に書き込み競合で文字化け行が混入するが実データの欠損ではない。
- 集計時は`LC_ALL=C`でsort/uniqしないと、macOS/BSD `sort`のUTF-8照合の癖で同一の日本語文字列が正しく集約されない（`en_US.UTF-8`ロケールでは元の行順のまま返り、`uniq -c`が同一値を別集計してしまう）。
- 実行環境として、OllamaサービスはこのMac自身のTailscale IP（`100.71.107.6:11434`）にのみバインドされており、`localhost:11434`では接続拒否になる。詳細は[[ollama_tailscale_binding]]参照。

## 次の候補

- モデルサイズ（8b/14b）を揃えた比較run、またはC-1/C-2導入前後の比較runで要因切り分け
- NG率0%が継続するか、複数run（別の乱数シード相当）での再現性確認
