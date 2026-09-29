# 使い捨て検証スクリプト（依頼: think:trueの反復ループ再現テスト）
#
# 目的: bonsai2_run2でハングしたtenji_kata_hintの実プロンプト（log/observe_rg_last_prompt.log
# に記録されていたもの、verse13直前）を使い、think: false（現状） と think: true の
# 反復ループ・ハング発生頻度を比較する。本番コード(app/)は無変更。
#
# num_predict/repeat_penalty（今回実装済み・ollama_client.rb既定値）は両条件に
# 等しく効くため、「think」単独の変数を分離できる。
#
# 実行: bin/rails runner script/verify_think_true_repro.rb

require "net/http"
require "json"
require "benchmark"

MODEL   = "bonsai2-waka"
PROMPT  = <<~PROMPT
  前句：街の灯り見る人の姿
  連歌の付け句として、この句から転じる方向を3つ提案してください。

PROMPT
TRIALS  = 10
TIMEOUT = 600

def call(think:, trial:)
  uri  = URI("http://localhost:11434/api/generate")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = TIMEOUT

  req = Net::HTTP::Post.new(uri.path)
  req["Content-Type"] = "application/json"
  req.body = {
    model: MODEL, prompt: PROMPT, stream: false, think: think,
    options: { num_predict: OllamaClient::DEFAULT_NUM_PREDICT, repeat_penalty: OllamaClient::DEFAULT_REPEAT_PENALTY },
    temperature: 0.5
  }.to_json

  result = { think: think, trial: trial }
  elapsed = Benchmark.realtime do
    http_res = http.request(req)
    if http_res.is_a?(Net::HTTPSuccess)
      json = JSON.parse(http_res.body)
      response  = json["response"].to_s
      thinking  = json["thinking"].to_s
      result.merge!(
        status: "ok",
        eval_count: json["eval_count"],
        response_len: response.length,
        thinking_len: thinking.length,
        response_blank: response.strip.empty?,
        response_tail: response[-60, 60] || response
      )
    else
      result.merge!(status: "http_error_#{http_res.code}")
    end
  rescue Net::ReadTimeout
    result.merge!(status: "timeout")
  rescue => e
    result.merge!(status: "error_#{e.class}", error_message: e.message)
  end
  result[:elapsed_sec] = elapsed.round(1)
  result
end

results = []

puts "=" * 60
puts "think:false #{TRIALS}回"
puts "=" * 60
TRIALS.times do |i|
  r = call(think: false, trial: i + 1)
  results << r
  puts "  [#{i + 1}] #{r.inspect}"
end

puts "=" * 60
puts "think:true #{TRIALS}回"
puts "=" * 60
TRIALS.times do |i|
  r = call(think: true, trial: i + 1)
  results << r
  puts "  [#{i + 1}] #{r.inspect}"
end

File.write(
  Rails.root.join("log", "verify_think_true_repro_#{Time.now.strftime('%Y%m%d_%H%M')}.jsonl"),
  results.map(&:to_json).join("\n")
)

puts "=" * 60
puts "サマリー"
puts "=" * 60
[false, true].each do |th|
  subset = results.select { |r| r[:think] == th }
  ok        = subset.select { |r| r[:status] == "ok" }
  timeouts  = subset.count { |r| r[:status] == "timeout" }
  blank     = ok.count { |r| r[:response_blank] }
  avg_sec   = ok.empty? ? nil : (ok.sum { |r| r[:elapsed_sec] } / ok.size.to_f).round(1)
  avg_eval  = ok.empty? ? nil : (ok.sum { |r| r[:eval_count].to_i } / ok.size.to_f).round(1)
  puts "think:#{th} — ok=#{ok.size}/#{TRIALS} timeout=#{timeouts} response_blank=#{blank} avg_sec=#{avg_sec} avg_eval_count=#{avg_eval}"
end
