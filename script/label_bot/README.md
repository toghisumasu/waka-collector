# 手ラベル配信・回収（Telegram）

毎日 batch（20 句）を Telegram へ送り、ボタン操作を `tmp/gendai/labels.jsonl` に保存する。LLM は使わない。
既存の通知 Bot（toghisumasu_bot）・tg-listen とは**別の Bot・別プロセス**。

## 設定（ユーザーが行う）
1. BotFather で新しい Bot を作る。
2. リポジトリ外に環境ファイルを作る（権限 0600）。
   ```
   mkdir -p ~/.config/label_bot && umask 077
   cat > ~/.config/label_bot/env <<'EOF'
   LABEL_BOT_TOKEN=（Bot のトークン）
   LABEL_BOT_CHAT_ID=（受信を許可する chat_id）
   EOF
   chmod 600 ~/.config/label_bot/env
   ```
   権限が 0600 でないと、スクリプトは起動を拒否する。
3. chat_id が分からないときは、新しい Bot に何か送ってから `LABEL_BOT_ENV_FILE=~/.config/label_bot/env ruby script/label_bot/whoami.rb`（最後のメッセージの chat_id だけを表示。トークンは表示しない。先に環境ファイルには `LABEL_BOT_TOKEN` だけ書けばよい）。
4. 手動実行は `LABEL_BOT_ENV_FILE=~/.config/label_bot/env ruby script/label_bot/send_batch.rb`（常駐は `poll.rb`）。
5. 自動化は `launchd/*.plist.example` を複製し、パスを置き換えて `~/Library/LaunchAgents` に置き、`launchctl load` する（雛形のみ・配置はユーザー）。

## データ（`tmp/gendai/`、追跡対象外）
- 入力: `batches/day{N}.json` = `[{ "id", "form", "text" }, ...]`（`key.json` は読まない）
- `sent.jsonl`（配信・リマインダー・完了の記録）、`labels.jsonl`（追記のみ）、`labels.csv`（現在値）、`offset.json`
- `LABEL_BOT_DIR` で置き場を変えられる（テスト用）。

## 動作
- 同じ日（JST）に 2 回実行しても、2 回目は何も送らない（`sent.jsonl` の日付で判定）。
- 前の batch が未完了のあいだは、残り件数のリマインダーだけを送る。
- 途中で送信に失敗した場合、その batch は「配信済み」として先に記録される（二重配信の防止）。送れた件数は `sent.jsonl` の `batch_partial` に残り、**次の `send_batch.rb` の実行で、未送信の句だけを送り直す**（同日でも実行。`batch_resume` / `batch_resumed` を記録）。全件送れるまで、次の batch もリマインダーも送らない。全件送れたら通常のゲートに戻る。
- 通信が失敗した瞬間にメッセージが実は届いていた場合のみ、その 1 句が重複しうる（Telegram 側の応答が取れないため判別できない）。
- 許可した chat_id 以外の更新は無視する。`/memo <番号> <文>` の番号は、メッセージ冒頭の `N/20` の N。
