# frozen_string_literal: true

require "net/http"
require "json"

class OllamaClient
  API_URL      = "http://localhost:11434/api/generate"
  API_URL_CHAT = "http://localhost:11434/api/chat"
  MODEL = "qwen3:8b"
  MAX_TOOL_LOOPS = 5

  # localhostへの接続確立は通常ミリ秒単位で完了するため、Rubyデフォルトの
  # 60秒より大幅に短く固定する（其の四十 D-40-1）。
  OPEN_TIMEOUT = 5

  def self.generate(prompt, timeout: 300, think: true, temperature: nil)
    uri  = URI(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = timeout

    # think: true のとき /no_think トークンを先頭に付加
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    body = { model: MODEL, prompt: prompt, stream: false, think: think }
    body[:temperature] = temperature if temperature
    req.body = { model: MODEL, prompt: prompt, stream: false, think: think }.to_json

    res = http.request(req)
    JSON.parse(res.body)["response"]
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end

  # messages: [{ role:, content: }, ...]
  # tools不要の複数ターン会話用（其の三十一 Step C-3）
  def self.chat(messages, timeout: 300, think: false)
    uri  = URI(API_URL_CHAT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = timeout
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req.body = {
      model: MODEL,
      messages: messages,
      stream: false,
      think: think
    }.to_json
    res = JSON.parse(http.request(req).body)
    res.dig("message", "content")
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end

  # messages: [{ role:, content: }, ...]
  # tools:    Ollama形式のツール定義配列
  # ブロックに |tool_name, arguments_hash| が渡される。
  # ブロックの戻り値（Hash）がツール実行結果としてメンタムさんに返される。
  def self.chat_with_tools(messages, tools:, timeout: 300, think: false)
    messages = messages.dup
    uri  = URI(API_URL_CHAT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = timeout

  MAX_TOOL_LOOPS.times do |i|
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req.body = {
      model: MODEL, messages: messages, tools: tools,
      stream: false, think: think
    }.to_json

    t0 = Time.now
    res = JSON.parse(http.request(req).body)
    elapsed = (Time.now - t0).round(1)

    message = res["message"]
    tool_calls = message["tool_calls"]
    Rails.logger.info "[chat_with_tools] loop #{i + 1}/#{MAX_TOOL_LOOPS}: #{elapsed}秒, tool_calls=#{tool_calls&.size || 0}"

    return message["content"] if tool_calls.nil? || tool_calls.empty?

    messages << message
    tool_calls.each do |call|
      name = call.dig("function", "name")
      args = call.dig("function", "arguments")
      result = yield(name, args)
      Rails.logger.info "[chat_with_tools]   tool_call: #{name}(#{args.inspect}) => #{result.inspect}"
      messages << { role: "tool", tool_name: name, content: result.to_json }
    end
  end

    raise "ツール呼び出しが#{MAX_TOOL_LOOPS}回を超えました（無限ループ防止）"
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end
end

