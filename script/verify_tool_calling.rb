require 'net/http'
require 'json'
require 'benchmark'

API_URL = "http://localhost:11434/api/chat"
MODEL   = "qwen3:8b"

tools = [
  {
    type: "function",
    function: {
      name: "count_mora",
      description: "与えられた日本語の句のモーラ数（拍数）を正確に数える",
      parameters: {
        type: "object",
        required: ["text"],
        properties: {
          text: { type: "string", description: "モーラ数を数えたい句のテキスト" }
        }
      }
    }
  }
]

messages = [
  { role: "user", content: "「春吹き渡る」という句のモーラ数（音数）を教えてください。" }
]

def post_chat(messages, tools)
  uri = URI(API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 300
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = { model: MODEL, messages: messages, tools: tools, stream: false, think: true }.to_json
  JSON.parse(http.request(req).body)
end

puts "=== 1回目のリクエスト ==="
res1 = nil
t1 = Benchmark.realtime { res1 = post_chat(messages, tools) }
puts "所要時間: #{t1.round(1)}秒"

tool_calls = res1.dig("message", "tool_calls")
if tool_calls.nil? || tool_calls.empty?
  puts "tool_callsなし。content:"
  puts res1.dig("message", "content")
  exit
end

call = tool_calls.first
text = call["function"]["arguments"]["text"]
puts "ツール呼び出し: #{call['function']['name']}(text: \"#{text}\")"

mora = KuValidator.new(text).count_mora
puts "KuValidator結果: #{mora}モーラ"

messages << res1["message"]
messages << { role: "tool", tool_name: "count_mora", content: { mora: mora }.to_json }

puts "=== 2回目のリクエスト ==="
res2 = nil
t2 = Benchmark.realtime { res2 = post_chat(messages, tools) }
puts "所要時間: #{t2.round(1)}秒"

puts "=== 最終応答 ==="
puts res2.dig("message", "content")
puts "=== 合計: #{(t1 + t2).round(1)}秒 ==="
