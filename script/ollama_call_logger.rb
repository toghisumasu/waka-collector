# frozen_string_literal: true

# Ollama呼び出し単位の計測ログ（観測専用・app/ 無変更）。
#
# observe_renga_generator.rb から OBSERVE_RG_CALL_LOG=1 のときだけ require される。
# 未設定時は何もロードされず、従来の観測挙動は完全に不変。
#
# 記録(JSONL、1呼び出し1行): log/observe_rg_calls_<日時><suffix>.jsonl
#   verse_no / attempt     … 観測ループの句番号・外側リトライ番号（$OBS_CTX）
#   call_seq               … 同一(verse_no, attempt)内の呼び出し通番（=内部試行の目安）
#   api / kind / line      … generate|chat、呼び出し元メソッド名、呼び出し元行番号
#   elapsed_sec / timed_out / error
#   timeout_sec            … 実際に効いたタイムアウト（観測側の底上げ後の値）
#   prompt_chars           … プロンプト長（chatはcontent合計）
#   eval_count / prompt_eval_count / total_duration_ms / load_duration_ms
#                          … Ollamaレスポンスから取得（タイムアウト時は nil）
#
# タイムアウト値は一切変更しない（効いた値を記録するだけ）。
# eval_count等は OllamaClient が response 文字列しか返さないため、
# Net::HTTP#request を prepend してレスポンスJSONを横取りして取得する。

require "json"
require "net/http"

$OBS_CTX = { verse_no: nil, attempt: nil } # rubocop:disable Style/GlobalVars

module OllamaCallMeta
  def request(req, *args, &blk)
    res = super
    if req.path.to_s.match?(%r{/api/(generate|chat)\z})
      begin
        j = JSON.parse(res.body)
        Thread.current[:ollama_call_meta] = {
          eval_count:         j["eval_count"],
          prompt_eval_count:  j["prompt_eval_count"],
          total_duration_ms:  j["total_duration"] && (j["total_duration"] / 1_000_000.0).round(1),
          load_duration_ms:   j["load_duration"] && (j["load_duration"] / 1_000_000.0).round(1)
        }
      rescue StandardError
        Thread.current[:ollama_call_meta] = nil
      end
    end
    res
  end
end
Net::HTTP.prepend(OllamaCallMeta)

module OllamaCallLogger
  CALL_LOG = Rails.root.join(
    "log",
    "observe_rg_calls_#{Time.now.strftime('%Y%m%d_%H%M%S')}" \
    "#{ENV['OBSERVE_RG_SUFFIX'].present? ? "_#{ENV['OBSERVE_RG_SUFFIX']}" : ''}.jsonl"
  ).to_s

  @seq = Hash.new(0)

  def self.record(api:, prompt_chars:, timeout:, caller_loc:)
    ctx = $OBS_CTX # rubocop:disable Style/GlobalVars
    key = [ctx[:verse_no], ctx[:attempt]]
    @seq[key] += 1
    Thread.current[:ollama_call_meta] = nil
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entry = {
      ts: Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      verse_no: ctx[:verse_no], attempt: ctx[:attempt], call_seq: @seq[key],
      api: api, kind: caller_loc&.label, line: caller_loc&.lineno,
      prompt_chars: prompt_chars, timeout_sec: timeout
    }
    begin
      result = yield
      entry[:timed_out] = false
      result
    rescue StandardError => e
      entry[:timed_out] = e.message.include?("タイムアウト")
      entry[:error] = e.message[0, 200]
      raise
    ensure
      entry[:elapsed_sec] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)
      entry.merge!(Thread.current[:ollama_call_meta] || {})
      File.open(CALL_LOG, "a") { |f| f.puts(entry.to_json) }
    end
  end

  def generate(prompt, **kwargs)
    OllamaCallLogger.record(api: "generate", prompt_chars: prompt.to_s.length,
                            timeout: kwargs[:timeout], caller_loc: caller_locations(1, 1)&.first) { super }
  end

  def chat(messages, **kwargs)
    chars = Array(messages).sum { |m| (m[:content] || m["content"]).to_s.length }
    OllamaCallLogger.record(api: "chat", prompt_chars: chars,
                            timeout: kwargs[:timeout], caller_loc: caller_locations(1, 1)&.first) { super }
  end
end
OllamaClient.singleton_class.prepend(OllamaCallLogger)
puts "[call-log] Ollama呼び出し計測ログ: #{OllamaCallLogger::CALL_LOG}"
