# frozen_string_literal: true
# G-1: bui候補語彙抽出スクリプト
#
# 使い方:
#   bin/rails runner script/extract_bui_candidates.rb LOG1 [LOG2 ...]
#   例: bin/rails runner script/extract_bui_candidates.rb log/observe_rg_20260923.log
#
# 処理フロー:
#   新フォーマットログ（句本文付き、第7フィールド）→ bui空行（第5フィールド空）のみ抽出
#   → 句本文をMeCabで形態素解析 → 内容語（名詞・形容詞・副詞）を抽出
#   → app/data/bui_dictionary.ymlの既存見出し語と照合し未登録語のみ残す
#   → wakas（八代集、season列は無いためSEASON_WORDSで動的判定）で出現首数・代表seasonを付加
#   → 出現回数降順でCSV出力（tmp/bui_candidates_YYYYMMDD.csv）
#
# 旧フォーマット（句本文なし、6フィールド）の行は自動的にスキップする。
# 出力はあくまで人力判断のための参考表示（推奨bui候補・八代集集計）であり、
# app/data/bui_dictionary.yml自体は変更しない（読み取り専用）。

require "yaml"
require "csv"
require "natto"
require "set"

if ARGV.empty?
  puts "使い方: bin/rails runner script/extract_bui_candidates.rb LOG1 [LOG2 ...]"
  exit 1
end

BUI_DICT_PATH  = Rails.root.join("app", "data", "bui_dictionary.yml")
EXISTING_WORDS = YAML.load_file(BUI_DICT_PATH).keys.to_set
CONTENT_POS    = %w[名詞 形容詞 副詞].freeze

PLANT_HINTS     = %w[花 草 木 葉 根].freeze
WATERSIDE_HINTS = %w[水 川 海 池 浜 浦 磯].freeze
SKY_HINTS       = %w[空 雲 雪 雨 霞 霜].freeze
SEASON_BUI_HINT = { "春" => "植物候補", "夏" => "植物候補", "秋" => "植物候補", "冬" => "降物候補" }.freeze

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end

# 内容語（名詞・形容詞・副詞）の表層形を配列で返す
def content_words(text, nm)
  return [] if text.nil? || text.strip.empty?

  words = []
  nm.parse(text.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos?
    pos = node.feature.split(",")[0]
    words << node.surface if CONTENT_POS.include?(pos)
  end
  words
end

# ログ1行をパースする。新フォーマット（句本文あり、7フィールド）のみ扱い、
# 旧フォーマット（6フィールド、句本文なし）はnilを返してスキップさせる。
def parse_log_line(line)
  line = line.strip
  return nil if line.empty?

  line = line.sub(/^\[[^\]]+\]\s*/, "")
  cols = line.split("|").map(&:strip)
  return nil if cols.size < 7

  { word: cols[1], bui: cols[4], text: cols[6] }
end

# wakasにseasonカラムが無いため、本文中の季語（SEASON_WORDS）から動的判定する。
def season_of(text)
  RengaGenerator::SEASON_WORDS.find { |_, words| words.any? { |w| text.include?(w) } }&.first
end

# 対象語を含む八代集の歌を検索し、出現首数と代表季節（本文季節の多数決）・その比率を返す。
def hachidaishu_stats(word)
  pattern = "%#{ActiveRecord::Base.sanitize_sql_like(word)}%"
  poems = Waka.where("upper_phrase_text LIKE :w OR lower_phrase_text LIKE :w", w: pattern)
  count = poems.count
  return { count: 0, season: nil, ratio: 0.0 } if count.zero?

  seasons = poems.filter_map { |p| season_of("#{p.upper_phrase_text}#{p.lower_phrase_text}") }
  return { count: count, season: nil, ratio: 0.0 } if seasons.empty?

  top_key, top_n = seasons.tally.max_by { |_, n| n }
  { count: count, season: RengaGenerator::SEASON_JP[top_key], ratio: top_n.to_f / seasons.size }
end

def suggest_bui(word, season, ratio)
  return "植物" if PLANT_HINTS.any? { |h| word.include?(h) }
  return "水辺候補" if WATERSIDE_HINTS.any? { |h| word.include?(h) }
  return "降物または聳物候補" if SKY_HINTS.any? { |h| word.include?(h) }
  return SEASON_BUI_HINT[season] if season && ratio >= 0.6

  ""
end

nm = build_mecab
word_counts = Hash.new(0)

ARGV.each do |path|
  unless File.exist?(path)
    warn "ファイルが見つかりません: #{path}"
    next
  end

  File.foreach(path, encoding: "UTF-8") do |line|
    row = parse_log_line(line)
    next unless row
    next unless row[:bui].to_s.empty? # bui空行のみ対象

    content_words(row[:text], nm).each { |w| word_counts[w] += 1 }
  end
end

candidates = word_counts.reject { |w, _| EXISTING_WORDS.include?(w) }

rows = candidates.map do |word, freq|
  stats = hachidaishu_stats(word)
  bui_hint = suggest_bui(word, stats[:season], stats[:ratio])
  [word, freq, stats[:count], stats[:season], bui_hint, ""]
end.sort_by { |r| -r[1] }

out_path = Rails.root.join("tmp", "bui_candidates_#{Time.now.strftime('%Y%m%d')}.csv")
CSV.open(out_path, "w") do |csv|
  csv << %w[surface 出現回数 八代集出現首数 代表season 推奨bui候補 備考]
  rows.each { |r| csv << r }
end

puts "出力: #{out_path}（#{rows.size}語）"
