# 依頼書 G-2: Ollama呼び出し計測付き 031句走行(現行コード × Ollama v0.40.15)

## 目的
G-0(新コード)・G-1(旧コード)で見えた「裾の長い遅延」「600秒タイムアウト」が、
コード側(リトライ・プロンプト肥大)か Ollama 側(生成が長い/ロードが遅い/無応答)かを、
呼び出し単位のログで切り分ける。**今回は計測のみ。原因対策や A/B は結果を見てから別依頼。**

## 前提(実装済み・script/ のみ。app/ 無変更)
- `script/ollama_call_logger.rb`(新規)と `script/observe_renga_generator.rb`(+4行)
- `OBSERVE_RG_CALL_LOG=1` を付けたときだけ有効。未指定なら従来の観測と完全に同一
- **タイムアウトは変更なし**(観測側の既定 600 秒のまま。効いた値を記録するだけ)
- ゲートチェック: 121 pass / 0 fail を確認済み(2026-11-09)

## 走行条件
- コード: 現行 HEAD(未コミットの上記 script 変更を含む)
- Ollama: v0.40.15 / モデル qwen3:14b / `:direct`
- 句数: **031 句まで**(`OBSERVE_RG_TOTAL=31`)
- 走行は**ユーザーが直接ターミナルから手動起動**(tmux内は不安定になり得る)。他セッションの Ollama 利用がないことを事前に確認

## 起動前チェック
```bash
cd /Volumes/externalHDD/projects/waka-collector
git status --short script/            # ollama_call_logger.rb(??) と observe_renga_generator.rb(M)
curl -s localhost:11434/api/version   # または OLLAMA_URL 先の /api/version
curl -s localhost:11434/api/ps        # 他モデルがロード中でないこと
```

## 起動コマンド
```bash
OBSERVE_RG_CALL_LOG=1 OBSERVE_RG_TOTAL=31 OBSERVE_RG_SUFFIX=g2_calllog_ollama0.40.15 \
WAKA_OLLAMA_MODEL=qwen3:14b OLLAMA_URL=http://100.71.107.6:11434 \
bin/rails runner script/observe_renga_generator.rb
```
(G-0/G-1 と同じ OLLAMA_URL。Mac mini 上で直接走らせる場合は `OLLAMA_URL` を localhost に。)

## 出力
- 句ログ: `log/observe_rg_YYYYMMDD_g2_calllog_ollama0.40.15.log`
- **呼び出しログ**: `log/observe_rg_calls_YYYYMMDD_HHMMSS_g2_calllog_ollama0.40.15.jsonl`
  - 項目: verse_no, attempt(外側リトライ), call_seq(同一句・試行内の通番), api(generate/chat),
    kind(呼び出し元メソッド名), line, elapsed_sec, timed_out, timeout_sec, prompt_chars,
    eval_count, prompt_eval_count, total_duration_ms, load_duration_ms
  - タイムアウト時は eval_count 等が nil(レスポンスなし)で、error にメッセージが入る

## 事後解析で見る点(走行後に私が実施)
1. 遅い句(>300秒)の内訳: 呼び出し回数(リトライ多さ)か、1回の elapsed か
2. 遅い呼び出しの eval_count: 大きければ「生成が長い(反復ループ疑い)」、小さいのに遅ければ
   「ロード/待機(load_duration_ms)や無応答」
3. prompt_chars と elapsed の相関(プロンプト肥大の寄与)
4. kind 別の elapsed 分布(tenji_kata_hint / step0_miitate / 本体生成 / socratic chat)
5. G-0 レポートの交絡リストのうち、どれが裏付けられる/否定されるか

## 注意
- 600秒タイムアウトが再発したら、その時点の `/api/ps` と Ollama 側の状態を**中断直後に**記録しておく
  (G-1 では未確認事項として残った)
- 31句は n が小さい。結論は断定せず、傾向と次の一手の提案に留める
- 呼び出しログは非コミット(log/ は gitignore 対象)。必要な集計は docs/ のレポートにまとめる
