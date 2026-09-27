# frozen_string_literal: true
# bonsai2-waka「意図の一貫性」検証スクリプト
#
# 背景: 依頼書M-2の実時間再計測（script/measure_compare_walltime.rb）で
# bonsai2-wakaが前句8「かきねをとへばあらはなるみち」に対して
# 「おみちのぞるや重く重くしる重」（語の反復を含む）を生成した。
# Nobusonから「生成前に構想を聞くことと、生成後に説明を求めることを
# 比べれば、一貫した意図を持って詠んでいるのか、後付けの尤もらしい
# 説明をしているだけなのかを検証できるのでは」との提案を受け、
# 3ステップで比較する:
#
#   Step1（構想）: 実際の付句本文を生成させる前に、「次にどう付けるか」
#                  の構想（情景・心情・展開）だけを言語化させる。
#   Step2（生成）: 通常の:direct方式で実際に付句を生成させる
#                  （app/のRengaGenerator経由、compare_models.rbと同じ
#                  monkey-patchでmodelをbonsai2-wakaへ強制）。
#   Step3（事後説明）: Step2で生成された句そのものを見せ、その意味・
#                  意図を事後的に説明させる。
#
# 判定は人間が行う（本スクリプトは3つの応答を並べて出力するのみ）。
# 参考情報として、構想文/事後説明文と実際の生成句との内容語重複を
# 機械的に算出するが、これは一致度の目安であり自動判定ではない。
#
# 実行: bin/rails runner script/verify_bonsai_intent.rb
# app/配下は無変更。DB書き込みなし。

require "net/http"
require "json"
require "natto"

$COMPARE_MODEL      = "bonsai2-waka"
$LAST_RESPONSE_META = nil

# compare_models.rb / measure_compare_walltime.rbと同一のmonkey-patch
# （system:""でModelfile側SYSTENを無効化、modelを$COMPARE_MODELへ強制）。
module VerifyIntentPatch
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

    JSON.parse(http_res.body)["response"]
  end
end
OllamaClient.singleton_class.prepend(VerifyIntentPatch)

MAEKU_TEXT = "かきねをとへばあらはなるみち"
MAEKU_VT   = :tanku
TARGET_VT  = :chouku # target_verse_type(:tanku) と同じ（付句は長句）

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end

NM = build_mecab
CONTENT_POS_IPADIC = %w[名詞 動詞 形容詞 副詞].freeze

def content_words(text)
  words = []
  NM.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos? || node.surface.empty?
    pos = node.feature.split(",").first
    words << node.surface if CONTENT_POS_IPADIC.include?(pos)
  end
  words
end

def overlap_words(a, b)
  wa = content_words(a).uniq
  wb = content_words(b).uniq
  wa & wb
end

puts "=" * 70
puts "bonsai2-waka 意図の一貫性検証"
puts "前句: #{MAEKU_TEXT}（#{MAEKU_VT}） → 付句: #{TARGET_VT}"
puts "=" * 70

# ─────────────────────────────────────────────────────────
# Step1: 構想（生成前）
# ─────────────────────────────────────────────────────────
concept_prompt = <<~PROMPT
  あなたは連歌の宗匠です。次の前句に付句（#{TARGET_VT == :chouku ? '長句・十七音' : '短句・十四音'}）を詠むにあたり、
  実際の句はまだ詠まず、まずどのような情景・心情・展開で付けるつもりか、
  その構想を短い散文で説明してください。

  前句: #{MAEKU_TEXT}
PROMPT

puts "\n--- Step1: 構想（生成前） ---"
concept =
  begin
    OllamaClient.generate(concept_prompt, timeout: 180, think: false, temperature: 0.6)
  rescue => e
    "(取得失敗: #{e.message})"
  end
puts concept

# ─────────────────────────────────────────────────────────
# Step2: 実際の生成（:direct方式、app/のRengaGenerator経由）
# ─────────────────────────────────────────────────────────
puts "\n--- Step2: 実際の生成（:direct方式） ---"
generator = RengaGenerator.new(
  MAEKU_TEXT, [], TARGET_VT,
  constraints: {
    verse_history: [], forbidden_bui: [], season_hint: nil,
    generation_strategy: :direct,
    batch_name: "verify_bonsai_intent"
  }
)
tsukeku =
  begin
    generator.generate_tsugeku
  rescue => e
    "(生成失敗: #{e.message})"
  end
puts tsukeku

# ─────────────────────────────────────────────────────────
# Step3: 事後説明（生成後）
# ─────────────────────────────────────────────────────────
explain_prompt = <<~PROMPT
  あなたは連歌の宗匠です。以下はある前句に対して詠まれた付句です。
  この付句にどのような意味・意図が込められているか、説明してください。

  前句: #{MAEKU_TEXT}
  付句: #{tsukeku}
PROMPT

puts "\n--- Step3: 事後説明（生成後） ---"
explanation =
  if tsukeku.to_s.start_with?("(生成失敗")
    "(付句が生成できなかったためスキップ)"
  else
    begin
      OllamaClient.generate(explain_prompt, timeout: 180, think: false, temperature: 0.6)
    rescue => e
      "(取得失敗: #{e.message})"
    end
  end
puts explanation

# ─────────────────────────────────────────────────────────
# 参考: 内容語の重複（一致度の目安、自動判定ではない）
# ─────────────────────────────────────────────────────────
puts "\n" + "=" * 70
puts "【参考】内容語の重複（人間の判定材料。一致=一貫性を保証するものではない）"
if tsukeku.to_s.start_with?("(生成失敗")
  puts "  付句が生成できなかったため算出不可"
else
  concept_overlap = overlap_words(concept, tsukeku)
  explain_overlap = overlap_words(explanation, tsukeku)
  puts "  構想文 ⇄ 実際の付句: 共有内容語 = #{concept_overlap.empty? ? '(なし)' : concept_overlap.join('、')}"
  puts "  事後説明 ⇄ 実際の付句: 共有内容語 = #{explain_overlap.empty? ? '(なし)' : explain_overlap.join('、')}"
end
