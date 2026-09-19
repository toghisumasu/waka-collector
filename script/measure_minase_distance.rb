# frozen_string_literal: true
# 水無瀬三吟 語彙非重複率（Jaccard距離）計測スクリプト
# 実行: bin/rails runner script/measure_minase_distance.rb

require "csv"
require "natto"

CONTENT_POS_IPADIC = %w[名詞 動詞 形容詞 副詞].freeze

# docs/minase_sangin_hyakuin.md から100句のテキストを抽出
md_path = Rails.root.join("docs", "minase_sangin_hyakuin.md")
verses = []

File.foreach(md_path) do |line|
  next unless line.start_with?("|")
  cols = line.split("|").map(&:strip)
  # cols[0]="" cols[1]=句番 cols[2]=句種 cols[3]=作者 cols[4]=本文
  next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
  verse_no = cols[1].to_i
  next unless verse_no >= 1 && verse_no <= 100
  text = cols[4]
  next if text.nil? || text.empty?
  verses << { no: verse_no, text: text }
end

verses.sort_by! { |v| v[:no] }
raise "水無瀬三吟100句が読み込めません（#{verses.size}句）" unless verses.size == 100

# 形態素解析関数
extract_words =
  if WakaUnidicAnalyzer.available?
    analyzer = WakaUnidicAnalyzer.new
    ->(text) {
      analyzer.analyze(text).select { |m|
        CONTENT_POS_IPADIC.any? { |pos| m.pos.start_with?(pos) }
      }.map(&:surface)
    }
  else
    # WakaUnidicAnalyzerが利用不可の場合はIPAdic辞書で代替
    nm = Natto::MeCab.new(userdic: Rails.root.join("dict", "user.dic").to_s)
    ->(text) {
      words = []
      nm.parse(text.gsub(/[\s　]+/, "")) do |node|
        next if node.is_eos? || node.surface.empty?
        pos = node.feature.split(",").first
        words << node.surface if CONTENT_POS_IPADIC.include?(pos)
      end
      words
    }
  end

# 99ペアの非重複率を計算
pairs = []

(0..98).each do |i|
  maeku   = verses[i]
  tsugeku = verses[i + 1]

  maeku_words   = extract_words.call(maeku[:text])
  tsugeku_words = extract_words.call(tsugeku[:text])

  shared = (maeku_words & tsugeku_words).uniq
  union  = (maeku_words | tsugeku_words).uniq

  non_overlap = union.empty? ? 1.0 : 1.0 - (shared.size.to_f / union.size)

  pairs << {
    pair_no:          i + 1,
    maeku_text:       maeku[:text],
    tsugeku_text:     tsugeku[:text],
    maeku_words:      maeku_words.uniq.join(" "),
    tsugeku_words:    tsugeku_words.uniq.join(" "),
    shared_words:     shared.join(" "),
    non_overlap_rate: non_overlap.round(6)
  }
end

# 統計計算
rates = pairs.map { |p| p[:non_overlap_rate] }
n      = rates.size
mean   = rates.sum / n.to_f
sorted = rates.sort
median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
variance = rates.sum { |r| (r - mean)**2 } / n.to_f
std_dev  = Math.sqrt(variance)

# ヒストグラム（0.2刻み、0.0〜1.0）
bucket_labels = (0..4).map { |i| "#{format("%.1f", i * 0.2)}-#{format("%.1f", (i + 1) * 0.2)}" }
bucket_counts = Array.new(5, 0)
rates.each do |r|
  idx = [(r / 0.2).floor.to_i, 4].min
  bucket_counts[idx] += 1
end

# 標準出力
puts ""
puts "=== 水無瀬三吟 語彙非重複率 基準値 ==="
puts "サンプル数 : #{n}ペア"
puts "最小値     : #{format("%.6f", rates.min)}"
puts "最大値     : #{format("%.6f", rates.max)}"
puts "平均値     : #{format("%.6f", mean)}"
puts "中央値     : #{format("%.6f", median)}"
puts "標準偏差   : #{format("%.6f", std_dev)}"
puts ""
puts "分布（ヒストグラム）:"
bucket_labels.each_with_index do |label, idx|
  count = bucket_counts[idx]
  bar   = "■" * [count, 40].min
  puts "#{label} : #{bar}  (#{count}件)"
end

# CSV出力
csv_path = Rails.root.join("tmp", "minase_distance_report.csv")
CSV.open(csv_path.to_s, "w", encoding: "UTF-8") do |csv|
  csv << %w[pair_no maeku_text tsugeku_text maeku_words tsugeku_words shared_words non_overlap_rate]
  pairs.each { |p| csv << p.values }
end

puts ""
puts "CSV出力: #{csv_path}"
