# 実行: bin/rails runner script/verify_chat_with_tools.rb
require "benchmark"

text = "春吹き渡る"
messages = [
  { role: "user", content: "「#{text}」という句のモーラ数（音数）を教えてください。" }
]

result = nil
elapsed = Benchmark.realtime do
  result = OllamaClient.chat_with_tools(messages, tools: [OllamaTools::COUNT_MORA]) do |name, args|
    OllamaTools.execute(name, args)
  end
end

puts "=== 最終応答 ==="
puts result
puts "=== 所要時間: #{elapsed.round(1)}秒 ==="

