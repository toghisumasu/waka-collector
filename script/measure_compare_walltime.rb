# frozen_string_literal: true
# 依頼書M-2 Phase1 (B): 実時間（壁時計時間）再計測。:direct方式のみ、
# 前句5句×モデル2種×1回試行＝10生成。
#
# 既存のeval_ms（script/compare_models.rb出力）はOllama応答のeval_duration
# （最後の1回のHTTP呼び出しのみ）であり、RengaGeneratorの内部5×5リトライ・
# Socratic対話を含む「実際にユーザーが待つ時間」ではない。本スクリプトは
# generate_tsugeku呼び出し全体をProcess.clock_gettime(CLOCK_MONOTONIC)で
# 計測し、リトライを含む壁時計時間を得る。
#
# 依頼書M-2 Phase1 (B)指示の反映: 各Ollama呼び出しの直前に
# $LAST_RESPONSE_META = nil を明示リセットする。Phase0で確認した
# 「タイムアウト時、例外がJSONパース前に発生するため$LAST_RESPONSE_METAが
# 直前の別呼び出しの値のまま残る」汚染バグ（script/compare_models.rbに
# 同じ構造で存在）を、この計測では踏襲しない。
#
# 実行: bin/rails runner script/measure_compare_walltime.rb
# app/配下は無変更。DB書き込みなし。

require "net/http"
require "json"
require "csv"

$COMPARE_MODEL      = nil
$LAST_RESPONSE_META = nil

module WalltimePatch
  def generate(prompt, timeout: 300, think: true, temperature: nil, model: OllamaClient::MODEL)
    model = $COMPARE_MODEL if $COMPARE_MODEL
    $LAST_RESPONSE_META = nil # (B) 呼び出し直前リセット
    do_request(OllamaClient::API_URL, timeout,
               { model: model, prompt: prompt, stream: false, think: think, system: "",
                 options: { num_ctx: 8192 } }.tap { |b| b[:temperature] = temperature if temperature })
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end

  def chat(messages, timeout: 300, think: false)
    model = $COMPARE_MODEL || OllamaClient::MODEL
    $LAST_RESPONSE_META = nil # (B) 呼び出し直前リセット
    do_request(OllamaClient::API_URL_CHAT, timeout,
               { model: model, messages: messages, stream: false, think: think, system: "",
                 options: { num_ctx: 8192 } },
               chat: true)
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end

  private

  def do_request(url, timeout, body, chat: false)
    uri  = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OllamaClient::OPEN_TIMEOUT
    http.read_timeout = timeout
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req.body = body.to_json
    http_res = http.request(req)
    raise "HTTP #{http_res.code}" unless http_res.is_a?(Net::HTTPSuccess)

    json = JSON.parse(http_res.body)
    $LAST_RESPONSE_META = {
      eval_count:    json["eval_count"],
      eval_duration: json["eval_duration"],
      load_duration: json["load_duration"]
    }
    chat ? json.dig("message", "content") : json["response"]
  end
end
OllamaClient.singleton_class.prepend(WalltimePatch)

# 前句5句（compare_models.rbのMAEKU_SETから、長句3・短句2を抽出。季節は
# 春秋冬雑の広がりを保つ）。
MAEKU_SUBSET = [
  { no: 1,  vt: :chouku, text: "雪ながら山本かすむ夕べかな",     season: "春" },
  { no: 5,  vt: :chouku, text: "月や猶霧わたる夜に残るらん",     season: "秋" },
  { no: 17, vt: :chouku, text: "はるゝまも袖は時雨の旅衣",       season: "冬" },
  { no: 4,  vt: :tanku,  text: "舟さす音もしるきあけがた",       season: "雑" },
  { no: 8,  vt: :tanku,  text: "かきねをとへばあらはなるみち",   season: "雑" },
].freeze

MODELS = ["qwen3:14b", "bonsai2-waka"].freeze

def target_verse_type(maeku_vt)
  maeku_vt == :chouku ? :tanku : :chouku
end

def warmup(model)
  $COMPARE_MODEL = model
  OllamaClient.generate("こんにちは", timeout: 180, think: false, temperature: 0.8, model: model)
  puts "  ウォームアップ完了: #{model}"
rescue => e
  puts "  ウォームアップ失敗（続行）: #{e.message}"
end

puts "=" * 60
puts "実時間再計測: #{MODELS.join(' vs ')} / :direct方式 / 前句#{MAEKU_SUBSET.size}句×1回試行"
puts "=" * 60

rows = []
MODELS.each do |model|
  puts "\n--- モデル: #{model} ---"
  warmup(model)

  MAEKU_SUBSET.each do |maeku|
    $COMPARE_MODEL = model
    vt = target_verse_type(maeku[:vt])

    generator = RengaGenerator.new(
      maeku[:text], [], vt,
      constraints: {
        verse_history: [], forbidden_bui: [], season_hint: nil,
        generation_strategy: :direct,
        batch_name: "compare_models_walltime"
      }
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw_error = nil
    tsukeku =
      begin
        generator.generate_tsugeku
      rescue => e
        raw_error = e.message
        ""
      end
    wall_sec = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)

    puts "  [#{model}/前句#{maeku[:no]}] wall=#{wall_sec}s " \
         "#{tsukeku.presence || "(空/#{raw_error})"}"
    rows << { model: model, maeku_no: maeku[:no], season: maeku[:season],
              tsukeku: tsukeku, raw_error: raw_error, wall_sec: wall_sec }
  end
end

out_path = Rails.root.join("tmp", "compare_walltime_#{Time.now.strftime('%Y%m%d_%H%M')}.csv")
CSV.open(out_path, "w") do |csv|
  csv << %w[model maeku_no season tsukeku raw_error wall_sec]
  rows.each { |r| csv << r.values_at(:model, :maeku_no, :season, :tsukeku, :raw_error, :wall_sec) }
end

puts "\n" + "=" * 60
puts "出力: #{out_path}（#{rows.size}行）"
puts "=" * 60
puts "\n【壁時計時間サマリ】モデル別"
rows.group_by { |r| r[:model] }.each do |model, group|
  secs = group.map { |r| r[:wall_sec] }
  puts "  #{model}: n=#{secs.size} 平均=#{(secs.sum / secs.size).round(1)}s " \
       "最小=#{secs.min}s 最大=#{secs.max}s"
end
