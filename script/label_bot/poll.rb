#!/usr/bin/env ruby
# frozen_string_literal: true

# ボタン操作・/memo を回収して保存する常駐プロセス（launchd の KeepAlive で再起動）。
#   LABEL_BOT_ENV_FILE=~/.config/label_bot/env ruby script/label_bot/poll.rb
require_relative "config"
require_relative "telegram_api"
require_relative "poller"

$stdout.sync = true
begin
  LabelBot::Config.load_env_file!
  poller = LabelBot::Poller.new(store: LabelBot::Store.new,
                                api: LabelBot::TelegramApi.new(token: LabelBot::Config.token),
                                chat_id: LabelBot::Config.chat_id)
rescue LabelBot::ConfigError => e
  warn "[poll] #{e.message}"
  exit 1
end

loop do
  poller.poll_once
rescue LabelBot::TelegramApi::Error => e
  warn "[poll] #{e.message}"
  sleep 10
end
