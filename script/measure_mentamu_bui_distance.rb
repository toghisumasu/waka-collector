# frozen_string_literal: true
# メンタム百韻 bui Jaccard距離計測スクリプト
# 使い方:
#   bin/rails runner script/measure_mentamu_bui_distance.rb BATCH1 [BATCH2 ...]
#
# BATCH名未指定時は利用可能なbatchを一覧表示して終了する。
# 例:
#   bin/rails runner script/measure_mentamu_bui_distance.rb \
#     sono39_run1_20260919 sono39_run2_20260919

require "csv"
require "natto"

# ---------------------------------------------------------------------------
# DBから observation_batch の Renga チェーンを順番に取り出す
# 返り値: Array of String (verse texts, 100句分)
# ---------------------------------------------------------------------------
def build_verse_chain(batch_name)
  rengas = Renga.where(observation_batch: batch_name).order(:id).to_a
  raise "batch '#{batch_name}' のRengaが見つかりません" if rengas.empty?

  # previous_renga_idでソートして先頭を見つける
  id_set    = rengas.map(&:id).to_set
  first     = rengas.find { |r| r.previous_renga_id.nil? || !id_set.include?(r.previous_renga_id) }
  raise "先頭Rengaが特定できません（batch: #{batch_name}）" unless first

  chain = [first]
  by_prev = rengas.index_by(&:previous_renga_id)
  loop do
    nxt = by_prev[chain.last.id]
    break unless nxt
    chain << nxt
  end

  # 発句（最初のmaeku）+ 各rengaのtsugeku = 全100句
  texts = [chain.first.maeku]
  chain.each { |r| texts << r.tsugeku }
  texts.compact.reject(&:empty?)
end

# ---------------------------------------------------------------------------
# bui抽出（BuiDictionary + MeCab）
# ---------------------------------------------------------------------------
def build_extractors
  nm       = Natto::MeCab.new(userdic: Rails.root.join("dict", "user.dic").to_s)
  bui_dict = BuiDictionary.new
  [nm, bui_dict]
end

def extract_bui(text, nm, bui_dict)
  bui_dict.detect_all(text.gsub(/[\s　]+/, ""), nm)
end

# ---------------------------------------------------------------------------
# Jaccard距離・加速度（measure_bui_distance.rbと同じ実装）
# ---------------------------------------------------------------------------
def bui_jaccard_distance(set_a, set_b)
  return 1.0 if set_a.empty? && set_b.empty?
  intersection = (set_a & set_b).size
  union        = (set_a | set_b).size
  1.0 - intersection.to_f / union
end

def calculate_acceleration(distances)
  distances.each_with_index.map { |d, i| i == 0 ? nil : (d - distances[i - 1]).round(6) }
end

# ---------------------------------------------------------------------------
# 統計計算
# ---------------------------------------------------------------------------
def print_stats(label, distances)
  n      = distances.size
  mean   = distances.sum / n.to_f
  sorted = distances.sort
  median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  std_dev = Math.sqrt(distances.sum { |d| (d - mean)**2 } / n.to_f)

  puts ""
  puts "=== #{label} ==="
  puts "サンプル数   : #{n}ペア"
  puts "最小値       : #{format("%.6f", distances.min)}"
  puts "最大値       : #{format("%.6f", distances.max)}"
  puts "平均値       : #{format("%.6f", mean)}"
  puts "中央値       : #{format("%.6f", median)}"
  puts "標準偏差     : #{format("%.6f", std_dev)}"
  puts "距離=0.0     : #{distances.count(0.0)}ペア"
  puts "距離=1.0     : #{distances.count(1.0)}ペア"
end

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
batches = ARGV.map(&:strip).reject(&:empty?)

if batches.empty?
  available = Renga.where.not(observation_batch: nil)
                   .distinct.pluck(:observation_batch).sort
  puts "observation_batch を引数で指定してください。"
  puts ""
  puts "利用可能なbatch一覧:"
  available.each { |b| puts "  #{b}" }
  exit 0
end

nm, bui_dict = build_extractors

all_results = []

batches.each do |batch|
  texts = build_verse_chain(batch)
  puts "#{batch}: #{texts.size}句 読み込み"
  raise "100句に満たない（#{texts.size}句）: #{batch}" unless texts.size >= 100

  texts = texts.first(100)
  bui_sets = texts.map { |t| extract_bui(t, nm, bui_dict) }

  distances = (0..98).map { |i| bui_jaccard_distance(bui_sets[i], bui_sets[i + 1]).round(6) }
  accels    = calculate_acceleration(distances)

  print_stats("#{batch} bui Jaccard距離", distances)
  puts "bui有り句数  : #{bui_sets.count { |b| !b.empty? }}/100"

  pairs = (0..98).map do |i|
    {
      batch:        batch,
      pair_no:      i + 1,
      maeku_no:     i + 1,
      maeku_text:   texts[i],
      maeku_bui:    bui_sets[i].join("・"),
      tsugeku_no:   i + 2,
      tsugeku_text: texts[i + 1],
      tsugeku_bui:  bui_sets[i + 1].join("・"),
      bui_distance: distances[i],
      acceleration: accels[i]
    }
  end
  all_results.concat(pairs)
end

# 水無瀬三吟との比較表示
puts ""
puts "=== 水無瀬三吟 参考値（比較用） ==="
puts "平均値: 0.794613 / 中央値: 1.000000 / 標準偏差: 0.323142"
puts "距離=0.0: 10ペア / 距離=1.0: 54ペア / bui有り: 100/100"

# CSV出力
csv_path = Rails.root.join("tmp", "mentamu_bui_distance_report.csv")
CSV.open(csv_path.to_s, "w", encoding: "UTF-8") do |csv|
  csv << %w[batch pair_no maeku_no maeku_text maeku_bui tsugeku_no tsugeku_text tsugeku_bui bui_distance acceleration]
  all_results.each { |p| csv << p.values }
end

puts ""
puts "CSV出力: #{csv_path}"
