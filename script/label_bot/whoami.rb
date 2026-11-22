#!/usr/bin/env ruby
# frozen_string_literal: true

# chat_id 確認用。新しい Bot に最後に送られたメッセージの chat_id だけを表示する。
# 先に Telegram で Bot にメッセージを 1 通送っておく。トークンは表示しない（環境ファイルから読む）。
#   LABEL_BOT_ENV_FILE=~/.config/label_bot/env ruby script/label_bot/whoami.rb
# getUpdates を offset なしで 1 回呼ぶだけなので、更新は消費されない（poll.rb と競合しない）。
require_relative "config"
require_relative "telegram_api"

module LabelBot
  module Whoami
    module_function

    # 更新の配列から、最後のメッセージ（通常メッセージ、またはボタン操作元のメッセージ）の chat_id を返す。なければ nil。
    def last_chat_id(updates)
      updates.reverse_each do |u|
        chat = u.dig("message", "chat") || u.dig("callback_query", "message", "chat")
        return chat["id"] if chat && chat["id"]
      end
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    LabelBot::Config.load_env_file!
    api = LabelBot::TelegramApi.new(token: LabelBot::Config.token)
    id = LabelBot::Whoami.last_chat_id(api.get_updates(timeout: 0))
    if id
      puts id
    else
      warn "[whoami] メッセージが見つかりません。新しい Bot に Telegram から何か送ってから、もう一度実行してください。"
      exit 1
    end
  rescue LabelBot::ConfigError, LabelBot::TelegramApi::Error => e
    warn "[whoami] #{e.message}"
    exit 1
  end
end
