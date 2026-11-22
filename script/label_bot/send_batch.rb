#!/usr/bin/env ruby
# frozen_string_literal: true

# 手ラベル用の次の batch を Telegram へ送る（毎日 07:30 JST に launchd から起動）。
#   LABEL_BOT_ENV_FILE=~/.config/label_bot/env ruby script/label_bot/send_batch.rb
require_relative "config"
require_relative "telegram_api"
require_relative "sender"

begin
  LabelBot::Config.load_env_file!
  api = LabelBot::TelegramApi.new(token: LabelBot::Config.token)
  LabelBot::Sender.new(store: LabelBot::Store.new, api: api, chat_id: LabelBot::Config.chat_id).run
rescue LabelBot::ConfigError, LabelBot::TelegramApi::Error => e
  warn "[send_batch] #{e.message}"
  exit 1
end
