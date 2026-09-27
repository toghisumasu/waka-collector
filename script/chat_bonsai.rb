# frozen_string_literal: true
# bonsai2-waka 対話型REPL
#
# 目的: qwen3:8bの時と同様、モデルの「癖」を対話で探ってからプロンプトを
# 調整するための手作業ツール。script/verify_bonsai_intent.rbで見えた
# 「構想プロンプトで反復ループ」「事後説明プロンプトでオウム返し」の
# 癖を踏まえ、プロンプトの言い回し・システムプロンプト有無・温度を
# その場で変えながら試せるようにする。
#
# 実行: bin/rails runner script/chat_bonsai.rb
#   （対話ループ。標準入力から複数行入力可、空行で送信）
#
# 特殊コマンド（行頭で入力）:
#   /reset            会話履歴をクリアする
#   /system <text>    以降のリクエストに system プロンプトを設定する
#                      （空文字にすると無効化。既定は空文字＝
#                      Modelfile内蔵SYSTEMを無効化した状態で開始する）
#   /temp <数値>       temperatureを変更する（既定0.6）
#   /think on|off      think（推論過程）を含めるか切り替える（既定off）
#   /history           現在の会話履歴をそのまま表示する
#   /exit または /quit  終了する
#
# app/配下は無変更。DB書き込みなし。会話ログはtmp/chat_bonsai_*.jsonlへ
# 逐次追記する（後で見返せるように。終了時にパスを表示する）。

require "net/http"
require "json"

module ChatBonsaiPatch
  def chat(messages, timeout: 300, think: false, temperature: nil, model: "bonsai2-waka")
    uri  = URI(OllamaClient::API_URL_CHAT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OllamaClient::OPEN_TIMEOUT
    http.read_timeout = timeout
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    body = { model: model, messages: messages, stream: false, think: think,
             options: { num_ctx: 8192 } }
    body[:temperature] = temperature if temperature
    req.body = body.to_json

    http_res = http.request(req)
    raise "HTTP #{http_res.code}: #{http_res.body}" unless http_res.is_a?(Net::HTTPSuccess)

    JSON.parse(http_res.body).dig("message", "content")
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end
end
OllamaClient.singleton_class.prepend(ChatBonsaiPatch)

def read_multiline
  puts "(複数行入力可。空行で送信 / 1行目が/コマンドなら即実行)"
  lines = []
  loop do
    line = $stdin.gets
    return nil if line.nil? # EOF (Ctrl-D)

    line = line.chomp
    return line if lines.empty? && line.start_with?("/")
    break if line.empty? && !lines.empty?
    break if line.empty? && lines.empty? && false # 空行のみで送信はしない（誤送信防止）

    lines << line
  end
  lines.join("\n")
end

system_prompt = ""
temperature   = 0.6
think         = false
messages      = []

log_path = Rails.root.join("tmp", "chat_bonsai_#{Time.now.strftime('%Y%m%d_%H%M')}.jsonl")
def log_turn(path, role, content)
  File.open(path, "a") { |f| f.puts({ ts: Time.now.iso8601, role: role, content: content }.to_json) }
end

puts "=" * 70
puts "bonsai2-waka 対話REPL"
puts "system=\"#{system_prompt}\" temperature=#{temperature} think=#{think}"
puts "ログ: #{log_path}"
puts "終了は /exit、コマンド一覧はファイル冒頭コメント参照"
puts "=" * 70

loop do
  print "\nあなた> "
  input = read_multiline
  break if input.nil?

  input = input.to_s.strip
  next if input.empty?

  if input.start_with?("/")
    cmd, _, arg = input.partition(" ")
    case cmd
    when "/exit", "/quit"
      break
    when "/reset"
      messages = []
      puts "→ 会話履歴をクリアしました"
    when "/system"
      system_prompt = arg
      puts "→ system = \"#{system_prompt}\""
    when "/temp"
      temperature = arg.to_f
      puts "→ temperature = #{temperature}"
    when "/think"
      think = (arg.strip == "on")
      puts "→ think = #{think}"
    when "/history"
      if messages.empty?
        puts "(履歴なし)"
      else
        messages.each { |m| puts "[#{m[:role]}] #{m[:content]}" }
      end
    else
      puts "不明なコマンド: #{cmd}"
    end
    next
  end

  messages << { role: "user", content: input }
  log_turn(log_path, "user", input)

  request_messages = system_prompt.present? ? [{ role: "system", content: system_prompt }] + messages : messages

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  reply =
    begin
      OllamaClient.chat(request_messages, timeout: 180, think: think, temperature: temperature)
    rescue => e
      "(エラー: #{e.message})"
    end
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

  messages << { role: "assistant", content: reply.to_s }
  log_turn(log_path, "assistant", reply.to_s)

  puts "\nbonsai2-waka(#{elapsed}s)> #{reply}"
end

puts "\n終了しました。ログ: #{log_path}"
