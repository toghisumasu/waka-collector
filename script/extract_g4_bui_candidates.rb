# frozen_string_literal: true
# 依頼書G-4 Phase1: BuiDictionary拡充候補の抽出（LLM活用・辞書反映なし）
#
# M-4で判明した「水無瀬三吟100句中55句でBuiDictionary#detect_allが空集合」
# のうち、人手注釈が存在する54句（no.100・挙句は注釈自体が無いため対象外）を
# 部立傾向ごとに4バッチへ分割し、qwen3:14bに見出し語候補を提案させる。
#
# 不変条件（依頼書G-4より）:
#   - LLMは候補出しにのみ使う。bui_dictionary.ymlへの反映は一切しない
#   - 全候補にsource_pair_no（元の水無瀬三吟句番）を必ず紐づける
#     （LLM出力中、対象バッチに存在しない句番を指した行は破棄する）
#   - 個別句のbui判定そのものはさせない（あくまで「この部立に該当する
#     見出し語は何か」という辞書語彙の提案のみ）
#
# バッチ分割（Phase0報告で提示・承認済み）:
#   1. 恋バッチ（12句、辞書登録0語）
#   2. 述懐バッチ（16句、辞書登録0語）
#   3. 居所バッチ（10句、辞書登録1語）
#   4. その他バッチ（山類・人倫・植物等の残り、複数部立に跨る句を含む）
#
# 実行: bin/rails runner script/extract_g4_bui_candidates.rb
# 出力: tmp/g4_bui_candidates.csv（コミット対象外、Nobusonレビュー用）
# app/配下・bui_dictionary.yml は無変更。DB書き込みなし。

require "csv"
require "net/http"
require "json"
require "set"

MODEL = "qwen3:14b"

# ─────────────────────────────────────────────────────────
# monkey-patch: モデル固定・system無効化（compare_models.rb等と同一方式）
# ─────────────────────────────────────────────────────────
module ExtractCandidatesPatch
  def generate(prompt, timeout: 300, think: true, temperature: nil, model: MODEL)
    uri  = URI(OllamaClient::API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OllamaClient::OPEN_TIMEOUT
    http.read_timeout = timeout
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    body = { model: model, prompt: prompt, stream: false, think: think, system: "",
             options: { num_ctx: 8192 } }
    body[:temperature] = temperature if temperature
    req.body = body.to_json

    http_res = http.request(req)
    raise "HTTP #{http_res.code}" unless http_res.is_a?(Net::HTTPSuccess)

    JSON.parse(http_res.body)["response"]
  rescue Net::ReadTimeout
    raise "メンタムさんへの接続がタイムアウトしました（#{timeout}秒）"
  rescue => e
    raise "Ollama接続エラー: #{e.message}"
  end
end
OllamaClient.singleton_class.prepend(ExtractCandidatesPatch)

# ─────────────────────────────────────────────────────────
# M-4で判明した55句のうち、人手注釈が存在する54句を読み込む
# （no.100は注釈自体が無いため対象外＝辞書ギャップではなくデータ欠落）
# ─────────────────────────────────────────────────────────
NA_VERSE_NOS = [6, 8, 9, 10, 11, 12, 14, 21, 22, 23, 26, 31, 33, 35, 36, 37, 38, 39, 40, 41, 42, 44, 46,
                50, 51, 54, 56, 64, 65, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79, 82, 83, 84, 85, 86, 88,
                89, 92, 93, 94, 95, 96, 97, 98, 99].freeze # 100は除外

md_path = Rails.root.join("docs", "minase_sangin_hyakuin.md")
verses = {}
File.foreach(md_path) do |line|
  next unless line.start_with?("|")
  cols = line.split("|").map(&:strip)
  next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
  no = cols[1].to_i
  next unless NA_VERSE_NOS.include?(no)

  verses[no] = { no: no, text: cols[4], raw_bui: cols[6].to_s }
end
raise "対象54句が揃いません（#{verses.size}件）" unless verses.size == NA_VERSE_NOS.size

# ─────────────────────────────────────────────────────────
# バッチ分割
# ─────────────────────────────────────────────────────────
def has_category?(raw_bui, category)
  raw_bui.split("・").map { |c| c.gsub(/（[^）]*）/, "").strip }.include?(category)
end

koi      = verses.values.select { |v| has_category?(v[:raw_bui], "恋") }
jukkai   = verses.values.select { |v| has_category?(v[:raw_bui], "述懐") }
kyosho   = verses.values.select { |v| has_category?(v[:raw_bui], "居所") }
covered  = (koi + jukkai + kyosho).map { |v| v[:no] }.to_set
sonota   = verses.values.reject { |v| covered.include?(v[:no]) }

BATCHES = [
  { label: "恋",     verses: koi },
  { label: "述懐",   verses: jukkai },
  { label: "居所",   verses: kyosho },
  { label: "その他", verses: sonota }
].freeze

puts "=" * 70
puts "G-4 Phase1: BuiDictionary拡充候補抽出（model=#{MODEL}）"
BATCHES.each { |b| puts "  #{b[:label]}バッチ: #{b[:verses].size}句" }
puts "=" * 70

# ─────────────────────────────────────────────────────────
# バッチごとにLLM呼び出し・出力パース
# ─────────────────────────────────────────────────────────
LINE_PATTERN = /\A(\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(.*)\z/

def build_prompt(label, batch_verses)
  lines = batch_verses.map { |v| "句番#{v[:no]}: 「#{v[:text]}」（人手注釈の部立: #{v[:raw_bui]}）" }
  <<~PROMPT
    あなたは日本古典文学・連歌の専門家です。以下は水無瀬三吟百韻の句と、
    人間の注釈者が付けた部立（式目上の句材分類）です。いずれの句も、
    現行の連歌式目辞書には該当する見出し語が未登録のため、機械的な
    部立判定ができていません。

    #{lines.join("\n")}

    各句について、その部立（#{label}を中心に、他の部立でも構いません）に
    該当する具体的な見出し語を、句の中から1〜2語ずつ提案してください。
    見出し語は句中に実際に現れる語（または現れる語の基本形）にしてください。
    存在しない語を創作しないでください。

    出力は句ごとに1行以上、以下の形式で厳密に出力してください
    （見出し・説明文・前置き・箇条書き記号は一切不要）：

    句番|見出し語|部立|根拠（20字程度）

    出力例：
    35|きぬぎぬ|恋|後朝の別れを表す恋の常套語
  PROMPT
end

def parse_response(text, valid_nos)
  candidates = []
  discarded  = 0
  text.to_s.each_line do |line|
    line = line.strip
    next if line.empty?

    # プロンプト中の「句番N: ...」表記をLLMが出力側でもそのまま踏襲する
    # ことがあるため（実測確認済み）、先頭の「句番」表記を許容して除去する。
    line = line.sub(/\A句番\s*/, "")
    m = LINE_PATTERN.match(line)
    next unless m

    pair_no = m[1].to_i
    unless valid_nos.include?(pair_no)
      discarded += 1
      next
    end

    candidates << { pair_no: pair_no, word: m[2].strip, bui: m[3].strip, note: m[4].strip }
  end
  [candidates, discarded]
end

all_rows = []
total_discarded = 0

BATCHES.each do |batch|
  next if batch[:verses].empty?

  valid_nos = batch[:verses].map { |v| v[:no] }.to_set
  prompt = build_prompt(batch[:label], batch[:verses])

  puts "\n--- #{batch[:label]}バッチ（#{batch[:verses].size}句）呼び出し中 ---"
  response =
    begin
      OllamaClient.generate(prompt, timeout: 180, think: false, temperature: 0.3)
    rescue => e
      puts "  エラー: #{e.message}（このバッチはスキップ）"
      nil
    end
  next if response.nil?

  candidates, discarded = parse_response(response, valid_nos)
  total_discarded += discarded
  puts "  取得候補: #{candidates.size}件（出典不明で破棄: #{discarded}件）"

  candidates.each do |c|
    source_verse = verses[c[:pair_no]]
    all_rows << {
      candidate_word:          c[:word],
      suggested_bui_category:  c[:bui],
      source_pair_no:          c[:pair_no],
      source_annotation:       source_verse[:raw_bui],
      llm_note:                c[:note]
    }
  end
end

# ─────────────────────────────────────────────────────────
# 出力
# ─────────────────────────────────────────────────────────
out_path = Rails.root.join("tmp", "g4_bui_candidates.csv")
headers = %i[candidate_word suggested_bui_category source_pair_no source_annotation llm_note]
CSV.open(out_path, "w") do |csv|
  csv << headers
  all_rows.each { |r| csv << r.values_at(*headers) }
end

puts "\n" + "=" * 70
puts "出力: #{out_path}（#{all_rows.size}件、出典不明で破棄した行: #{total_discarded}件）"
puts "=" * 70
puts "\n【部立別候補数（重複含む）】"
all_rows.group_by { |r| r[:suggested_bui_category] }.each do |cat, rows|
  puts "  #{cat}: #{rows.size}件"
end
puts "\n【見出し語の重複（同じ語が複数句から提案された場合）】"
all_rows.group_by { |r| r[:candidate_word] }.select { |_, rows| rows.size > 1 }.each do |word, rows|
  puts "  #{word}: #{rows.size}回（句番#{rows.map { |r| r[:source_pair_no] }.join(',')}）"
end

puts "\n※ このCSVはLLM提案の未検証リストです。bui_dictionary.ymlへの反映は"
puts "  一切行っていません。Phase2（Nobuson主導・一次資料での裏取り）を経てから"
puts "  採否を決定してください。"
