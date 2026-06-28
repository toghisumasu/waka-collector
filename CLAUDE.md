# waka-collector

古典連歌（百韻）をAI支援で作成・検証するRuby on Railsアプリケーション。

## セッション開始時の必須ゲートチェック

```bash
git log --oneline -5
git status
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null | tail -5
```
期待値: 55 pass / 0 fail（数は増える）。失敗時は作業禁止。

## アーキテクチャ

- **A層 (Ruby):** 式目の決定論的検証 — ShikimokuChecker
- **B層 (Ruby + YAML):** 候補フィルタ — bui_dictionary.yml, seed pool
- **C層 (LLM):** 付句生成 — qwen3:8b via Ollama（メンタムさん）
