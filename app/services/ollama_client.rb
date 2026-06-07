# frozen_string_literal: true

require "net/http"
require "json"

class OllamaClient
  API_URL = "http://localhost:11434/api/generate"
  MODEL   = "qwen3:8b"

  def self.generate(prompt, timeout: 300, think: true)
    uri  = URI(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = timeout

    # think: true のとき /no_think トークンを先頭に付加
    actual_prompt = think ? prompt : "/no_think\n#{prompt}"

    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req.body = { model: MODEL, prompt: actual_prompt, stream: false }.to_json

    res = http.request(req)
    JSON.parse(res.body)["response"]
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end
end
