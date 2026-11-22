# frozen_string_literal: true

require "net/http"
require "socket"
require "json"
require "uri"

module LabelBot
  # Telegram Bot API の薄いラッパー。トークンは URL にのみ使い、
  # 例外メッセージ・ログには出さない（[REDACTED] に置換）。
  #
  # 接続は IPv4 アドレスに固定する（IPv6 経路への接続が間欠的に確立できないため）。
  #   - Socket.getaddrinfo で AF_INET のみ取得し、Net::HTTP#ipaddr で接続先 IP を指定する。
  #   - TLS のホスト名検証と SNI は元のホスト名（api.telegram.org）のまま。証明書検証は無効にしない。
  #   - IPv4 が引けない場合は明確なエラーにする（IPv6 へは黙って切り替えない）。
  class TelegramApi
    class Error < StandardError; end

    OPEN_TIMEOUT = 5          # 接続確立の上限（秒）
    READ_TIMEOUT = 30         # 通常の API 呼び出しの応答待ち（秒）
    LONG_POLL_MARGIN = 15     # getUpdates の read_timeout は long polling の timeout にこの分を足す

    # host から IPv4 アドレスの配列を返す既定のリゾルバ（AF_INET のみ）
    DEFAULT_RESOLVER = lambda do |host|
      Socket.getaddrinfo(host, nil, Socket::AF_INET, Socket::SOCK_STREAM).map { |a| a[3] }.uniq
    end

    def initialize(token:, base: "https://api.telegram.org", resolver: DEFAULT_RESOLVER)
      @token = token
      @base = base
      @resolver = resolver
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
           read_timeout: timeout + LONG_POLL_MARGIN)
    end

    private

    def call(method, payload, read_timeout: READ_TIMEOUT)
      uri = URI("#{@base}/bot#{@token}/#{method}")
      ip = resolve_ipv4(uri.host)
      http = Net::HTTP.new(uri.host, uri.port) # SNI・証明書のホスト名検証は uri.host のまま
      http.ipaddr = ip                          # 接続先だけ IPv4 アドレスに固定する
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
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

    def resolve_ipv4(host)
      ip = Array(@resolver.call(host)).first
      raise Error, "IPv4 アドレスを解決できません（#{host}）。IPv6 へは切り替えません。" if ip.nil? || ip.to_s.empty?

      ip
    rescue SocketError => e
      raise Error, "IPv4 アドレスを解決できません（#{host}）: #{scrub(e.message)}。IPv6 へは切り替えません。"
    end

    def scrub(text)
      text.to_s.gsub(@token, "[REDACTED]")
    end
  end
end
