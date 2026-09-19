# frozen_string_literal: true
# 水無瀬三吟 bui Jaccard距離計測スクリプト
# 実行: bin/rails runner script/measure_bui_distance.rb

require "csv"

# 折情報マッピング（前句の句番で判定）
FOLD_MAP = [
  { range: (1..8),   ori: "初折",  men: "表" },
  { range: (9..22),  ori: "初折",  men: "裏" },
  { range: (23..36), ori: "二折",  men: "表" },
  { range: (37..50), ori: "二折",  men: "裏" },
  { range: (51..64), ori: "三折",  men: "表" },
  { range: (65..78), ori: "三折",  men: "裏" },
  { range: (79..92), ori: "名残折", men: "表" },
  { range: (93..99), ori: "名残折", men: "裏" },
].freeze

def fold_info(maeku_no)
  entry = FOLD_MAP.find { |f| f[:range].include?(maeku_no) }
  entry ? [entry[:ori], entry[:men]] : ["不明", "不明"]
end

def bui_jaccard_distance(set_a, set_b)
  return 1.0 if set_a.empty? && set_b.empty?
  intersection = (set_a & set_b).size
  union = (set_a | set_b).size
  1.0 - intersection.to_f / union
end

def calculate_acceleration(distances)
  distances.each_with_index.map do |d, i|
    i == 0 ? nil : (d - distances[i - 1]).round(6)
  end
end

# docs/minase_sangin_hyakuin.md から100句のテキスト・季・部立を抽出
md_path = Rails.root.join("docs", "minase_sangin_hyakuin.md")
verses = []

File.foreach(md_path) do |line|
  next unless line.start_with?("|")
  cols = line.split("|").map(&:strip)
  # cols[0]="" cols[1]=句番 cols[2]=句種 cols[3]=作者 cols[4]=本文 cols[5]=季 cols[6]=主な部立
  next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
  verse_no = cols[1].to_i
  next unless verse_no >= 1 && verse_no <= 100
  text = cols[4]
  next if text.nil? || text.empty?

  bui_raw = cols[6] || ""
  bui_set = bui_raw.split("・").map { |b| b.gsub(/（[^）]*）/, "").strip }.reject(&:empty?)

  verses << { no: verse_no, text: text, bui: bui_set }
end

verses.sort_by! { |v| v[:no] }
raise "水無瀬三吟100句が読み込めません（#{verses.size}句）" unless verses.size == 100

# 99ペアのbui Jaccard距離を計算
pairs = []
distances_only = []

(0..98).each do |i|
  maeku   = verses[i]
  tsugeku = verses[i + 1]

  distance = bui_jaccard_distance(maeku[:bui], tsugeku[:bui])
  distances_only << distance.round(6)
end

accelerations = calculate_acceleration(distances_only)

(0..98).each do |i|
  maeku   = verses[i]
  tsugeku = verses[i + 1]
  ori, men = fold_info(maeku[:no])

  pairs << {
    pair_no:      i + 1,
    ori:          ori,
    men:          men,
    maeku_no:     maeku[:no],
    maeku_text:   maeku[:text],
    maeku_bui:    maeku[:bui].join("・"),
    tsugeku_no:   tsugeku[:no],
    tsugeku_text: tsugeku[:text],
    tsugeku_bui:  tsugeku[:bui].join("・"),
    bui_distance: distances_only[i],
    acceleration: accelerations[i]
  }
end

# 統計計算
rates = distances_only
n      = rates.size
mean   = rates.sum / n.to_f
sorted = rates.sort
median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
variance = rates.sum { |r| (r - mean)**2 } / n.to_f
std_dev  = Math.sqrt(variance)

# 折ごとの平均
fold_groups = pairs.group_by { |p| [p[:ori], p[:men]] }
fold_order  = [
  ["初折", "表"], ["初折", "裏"],
  ["二折", "表"], ["二折", "裏"],
  ["三折", "表"], ["三折", "裏"],
  ["名残折", "表"], ["名残折", "裏"]
]

# Top5 加速度（絶対値降順）
top5_accel = pairs.reject { |p| p[:acceleration].nil? }
                  .sort_by { |p| -p[:acceleration].abs }
                  .first(5)

# Top5 最小距離（距離昇順）
top5_min = pairs.sort_by { |p| p[:bui_distance] }.first(5)

# 標準出力
puts ""
puts "=== 水無瀬三吟 bui Jaccard距離 基準値 ==="
puts "サンプル数 : #{n}ペア"
puts "最小値     : #{format("%.6f", rates.min)}"
puts "最大値     : #{format("%.6f", rates.max)}"
puts "平均値     : #{format("%.6f", mean)}"
puts "中央値     : #{format("%.6f", median)}"
puts "標準偏差   : #{format("%.6f", std_dev)}"

puts ""
puts "=== 折ごとの平均bui距離 ==="
fold_order.each do |ori, men|
  group = fold_groups[[ori, men]]
  next unless group && !group.empty?
  avg = group.sum { |p| p[:bui_distance] } / group.size.to_f
  puts "#{ori}#{men} (#{group.size}ペア) : #{format("%.6f", avg)}"
end

puts ""
puts "=== Top5 加速度（絶対値大）==="
top5_accel.each do |p|
  puts "pair#{p[:pair_no]} [#{p[:ori]}#{p[:men]}] #{p[:maeku_no]}→#{p[:tsugeku_no]}: acc=#{format("%+.6f", p[:acceleration])} dist=#{format("%.6f", p[:bui_distance])}"
end

puts ""
puts "=== Top5 最小bui距離 ==="
top5_min.each do |p|
  puts "pair#{p[:pair_no]} [#{p[:ori]}#{p[:men]}] #{p[:maeku_no]}→#{p[:tsugeku_no]}: dist=#{format("%.6f", p[:bui_distance])} | #{p[:maeku_bui]} / #{p[:tsugeku_bui]}"
end

# CSV出力
csv_path = Rails.root.join("tmp", "minase_bui_distance_report.csv")
CSV.open(csv_path.to_s, "w", encoding: "UTF-8") do |csv|
  csv << %w[pair_no ori men maeku_no maeku_text maeku_bui tsugeku_no tsugeku_text tsugeku_bui bui_distance acceleration]
  pairs.each { |p| csv << p.values }
end

puts ""
puts "CSV出力: #{csv_path}"
