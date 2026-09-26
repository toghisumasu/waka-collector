# frozen_string_literal: true
# 依頼書M: qwen3:14b × bonsai2-waka(27b) 付句生成比較
#
# 使い方: bin/rails runner script/compare_models.rb
#
# 設計判断（Phase0報告後、Nobuson再送の依頼書に明示的な回答が無かったため、
# 依頼書の不変条件「変数はモデルの1つだけ」を最優先して以下を採用）:
#
# 1. bonsai2-wakaのModelfileにSYSTEM行が存在する（qwen3:14bには無い）ため、
#    そのまま両モデルを叩くとSYSTEM有無という余計な変数が混入する。
#    本スクリプトはOllamaClient.generate/chatをmonkey-patch（app/は無変更）し、
#    全リクエストに system: "" を明示送信してModelfile側のSYSTEMを両モデルとも
#    無効化する。RengaGenerator/StepwiseWakaGeneratorのプロンプト文字列自体
#    （「あなたは連歌の宗匠です」等）は既存のまま一切変更しない。
# 2. StepwiseWakaGenerator（:waka_extraction）はmodel: "qwen3:14b"を3箇所
#    ハードコードしている（app/では変更しない、D-33-1回避）。同じmonkey-patch
#    層で $COMPARE_MODEL が設定されていれば強制的に上書きする。
# 3. eval_count/eval_duration/load_durationはOllamaClient.generateが
#    レスポンスから["response"]のみ返し破棄しているため、同じmonkey-patch層で
#    $LAST_RESPONSE_META に記録し、呼び出し元（本スクリプト）が読み出す。
# 4. RengaGenerator#generate_tsugekuはconstraints[:generation_strategy]で
#    :direct/:waka_extraction を切り替える単一の公開APIのため、両戦略とも
#    RengaGenerator.new(...).generate_tsugeku の呼び出しに統一する
#    （StepwiseWakaGeneratorを直接newしてpool/nm/bui_dictを自前構築する
#    必要はない。RengaGenerator内部で構築される）。
#
# app/配下は無変更。DB書き込みなし。log/observe_rg_*.log への追記もしない。

require "net/http"
require "json"
require "csv"
require "natto"
require "set"

# ─────────────────────────────────────────────────────────
# monkey-patch: モデル強制上書き・SYSTEM無効化・応答メタデータ捕捉
# ─────────────────────────────────────────────────────────
$COMPARE_MODEL      = nil
$LAST_RESPONSE_META = {}

module CompareModelsPatch
  def generate(prompt, timeout: 300, think: true, temperature: nil, model: OllamaClient::MODEL)
    model = $COMPARE_MODEL if $COMPARE_MODEL
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
OllamaClient.singleton_class.prepend(CompareModelsPatch)

# ─────────────────────────────────────────────────────────
# 前句セット（水無瀬三吟百韻、長句5・短句5）
# 水無瀬三吟には夏の句が0件（実測確認済み）のため、季節配分は春2・秋2・冬2・雑4。
# ─────────────────────────────────────────────────────────
MAEKU_SET = [
  { no: 1,  vt: :chouku, text: "雪ながら山本かすむ夕べかな", season: "春" },
  { no: 5,  vt: :chouku, text: "月や猶霧わたる夜に残るらん", season: "秋" },
  { no: 17, vt: :chouku, text: "はるゝまも袖は時雨の旅衣",   season: "冬" },
  { no: 11, vt: :chouku, text: "今更にひとり有る身をおもふなよ", season: "雑" },
  { no: 21, vt: :chouku, text: "見しはみな古郷人の跡もうし", season: "雑" },
  { no: 2,  vt: :tanku,  text: "行く水とほく梅にほふ里",     season: "春" },
  { no: 6,  vt: :tanku,  text: "霜おく野はら秋は暮れけり",   season: "秋" },
  { no: 32, vt: :tanku,  text: "たのむもはかなつま木とる山", season: "冬" },
  { no: 4,  vt: :tanku,  text: "舟さす音もしるきあけがた",   season: "雑" },
  { no: 8,  vt: :tanku,  text: "かきねをとへばあらはなるみち", season: "雑" },
].freeze

MODELS     = ["qwen3:14b", "bonsai2-waka"].freeze
STRATEGIES = [:direct, :waka_extraction].freeze
TRIALS     = 3

# ─────────────────────────────────────────────────────────
# 検証ヘルパー
# ─────────────────────────────────────────────────────────
class EchoDetector
  include VerseTextAnalysis

  def initialize(maeku)
    @maeku = maeku
    @verse_history = []
  end

  def echo?(text)
    maeku_echo?(text)
  end
end

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end

NM       = build_mecab
BUI_DICT = BuiDictionary.new

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

def run_trial(model, strategy, maeku, trial)
  $COMPARE_MODEL = model
  vt = target_verse_type(maeku[:vt])

  generator = RengaGenerator.new(
    maeku[:text], [], vt,
    constraints: {
      verse_history:       [],
      forbidden_bui:       [],
      season_hint:         nil,
      generation_strategy: strategy,
      # RengaGenerator内部ログ(log/renga_internal_*)・StepwiseStepLogger
      # (log/stepwise_steps_*.jsonl、run5/6等と共有ファイル)双方に
      # batch識別子を付け、既存の観測runログと混同されないようにする。
      batch_name:          "compare_models",
      log_context:         { batch: "compare_models", verse_no: maeku[:no], attempt: trial }
    }
  )

  raw_error = nil
  tsukeku =
    begin
      generator.generate_tsugeku
    rescue => e
      raw_error = e.message
      ""
    end

  meta = $LAST_RESPONSE_META.dup

  mora_ok      = tsukeku.present? ? (KuValidator.new(tsukeku, type: vt).validate[:result] != "ng") : false
  echo         = tsukeku.present? ? EchoDetector.new(maeku[:text]).echo?(tsukeku) : false
  bui          = tsukeku.present? ? BUI_DICT.detect_all(tsukeku, NM) : []

  checker = ShikimokuChecker.new
  shikimoku_ok =
    if tsukeku.present?
      word = BUI_DICT.detect_word(tsukeku, NM)
      candidate = { bui: bui, season: nil, verse_type: vt, word: word, text: tsukeku,
                    plant_type: BUI_DICT.plant_type(word) }
      violations = checker.all_violations([], candidate, bui_dict: BUI_DICT)
      violations += checker.ichiza_violations([], candidate)
      violations += checker.chotan_violations([], candidate)
      violations.empty?
    else
      false
    end

  {
    model: model, strategy: strategy.to_s, maeku_no: maeku[:no], trial: trial,
    tsukeku: tsukeku, raw: (raw_error || tsukeku.to_s)[0, 100],
    echo: echo, mora_ok: mora_ok, shikimoku_ok: shikimoku_ok, bui: bui.join(","),
    eval_ms: meta[:eval_duration] ? (meta[:eval_duration] / 1_000_000.0).round(1) : nil,
    load_ms: meta[:load_duration] ? (meta[:load_duration] / 1_000_000.0).round(1) : nil,
    eval_count: meta[:eval_count]
  }
end

# ─────────────────────────────────────────────────────────
# メイン
# ─────────────────────────────────────────────────────────
puts "=" * 60
puts "モデル比較: #{MODELS.join(' vs ')}"
puts "戦略: #{STRATEGIES.join(', ')} / 前句#{MAEKU_SET.size}句 × #{TRIALS}回試行"
puts "=" * 60

rows = []
MODELS.each do |model|
  puts "\n--- モデル: #{model} ---"
  warmup(model)

  STRATEGIES.each do |strategy|
    MAEKU_SET.each do |maeku|
      TRIALS.times do |i|
        trial = i + 1
        print "  [#{model}/#{strategy}/前句#{maeku[:no]}/trial#{trial}] "
        row = run_trial(model, strategy, maeku, trial)
        puts "#{row[:tsukeku].presence || '(空)'} " \
             "(echo=#{row[:echo]} mora=#{row[:mora_ok]} shikimoku=#{row[:shikimoku_ok]} " \
             "eval_ms=#{row[:eval_ms]})"
        rows << row
      end
    end
  end
end

out_path = Rails.root.join("tmp", "compare_models_#{Time.now.strftime('%Y%m%d_%H%M')}.csv")
CSV.open(out_path, "w") do |csv|
  csv << %w[model strategy maeku_no trial tsukeku raw echo mora_ok shikimoku_ok bui eval_ms load_ms eval_count]
  rows.each { |r| csv << r.values_at(:model, :strategy, :maeku_no, :trial, :tsukeku, :raw, :echo, :mora_ok, :shikimoku_ok, :bui, :eval_ms, :load_ms, :eval_count) }
end

puts "\n" + "=" * 60
puts "出力: #{out_path}（#{rows.size}行）"
puts "=" * 60
puts "\n【集計サマリ】モデル×戦略ごと"
rows.group_by { |r| [r[:model], r[:strategy]] }.each do |(model, strategy), group|
  n = group.size
  echo_rate      = (100.0 * group.count { |r| r[:echo] } / n).round(1)
  mora_rate      = (100.0 * group.count { |r| r[:mora_ok] } / n).round(1)
  shikimoku_rate = (100.0 * group.count { |r| r[:shikimoku_ok] } / n).round(1)
  eval_mss       = group.filter_map { |r| r[:eval_ms] }
  avg_eval_ms    = eval_mss.any? ? (eval_mss.sum / eval_mss.size).round(1) : nil
  puts "  #{model} / #{strategy}: n=#{n} echo率=#{echo_rate}% mora通過率=#{mora_rate}% " \
       "式目通過率=#{shikimoku_rate}% 平均eval_ms=#{avg_eval_ms}"
end
