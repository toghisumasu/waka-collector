# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module LabelBot
  # Telegram Bot API の薄いラッパー。トークンは URL にのみ使い、
  # 例外メッセージ・ログには出さない（[REDACTED] に置換）。
  class TelegramApi
    class Error < StandardError; end

    def initialize(token:, base: "https://api.telegram.org")
      @token = token
      @base = base
    end

    def send_message(chat_id:, text:, reply_markup: nil)
      call("sendMessage", { chat_id: chat_id, text: text, reply_markup: reply_markup }.compact)
    end

    def edit_reply_markup(chat_id:, message_id:, reply_markup:)
      call("editMessageReplyMarkup", { chat_id: chat_id, message_id: message_id, reply_markup: reply_markup })
    end

    def answer_callback(callback_query_id:, text: nil)
      call("answerCallbackQuery", { callback_query_id: callback_query_id, text: text }.compact)
    end

    def get_updates(offset: nil, timeout: 50)
      call("getUpdates", { offset: offset, timeout: timeout, allowed_updates: %w[message callback_query] }.compact,
           read_timeout: timeout + 15)
    end

    private

    def call(method, payload, read_timeout: 30)
      uri = URI("#{@base}/bot#{@token}/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = read_timeout
      req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      req.body = payload.to_json
      res = http.request(req)
      body = JSON.parse(res.body)
      raise Error, "Telegram API #{method} 失敗: HTTP #{res.code} #{scrub(body['description'])}" unless res.is_a?(Net::HTTPSuccess) && body["ok"]

      body["result"]
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Telegram API #{method} 通信エラー: #{e.class}: #{scrub(e.message)}"
    end

    def scrub(text)
      text.to_s.gsub(@token, "[REDACTED]")
    end
  end
end
