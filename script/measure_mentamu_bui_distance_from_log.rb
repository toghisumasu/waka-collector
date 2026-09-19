# frozen_string_literal: true
# メンタム百韻 bui Jaccard距離計測スクリプト（ログファイル版）
#
# 使い方:
#   ruby script/measure_mentamu_bui_distance_from_log.rb LOG1 [LOG2 ...]
#   ruby script/measure_mentamu_bui_distance_from_log.rb \
#     log/observe_rg_20260919_run1.log log/observe_rg_20260919.log
#
# 引数なし時は使い方を表示して終了。
#
# ログフォーマット（タイムスタンプあり/なし両対応）:
#   [timestamp] 001 | 検出語 | 長/短 | 季 | bui1,bui2 | status
#   または:
#   001 | 検出語 | 長/短 | 季 | bui1,bui2
#
# 注意:
#   ログの bui 列は BuiDictionary が実際に検出した部立カテゴリそのものです。
#   DB書き込みなし実行（:direct 戦略）でも bui 検出結果はここに記録されます。
#   ただし 100 句中の bui 検出率が低い（~20%）場合、ペア分類を参照してください。
#
# ペア分類:
#   Type A — 両句とも bui 有り（有意距離、水無瀬三吟と同条件で比較可能）
#   Type B — 片句のみ bui 有り（Jaccard距離 = 1.0 確定）
#   Type C — 両句とも bui 無し（部立比較不能）

require "csv"

# ---------------------------------------------------------------------------
# ログ解析
# ---------------------------------------------------------------------------
def parse_log_file(path)
  verses = {}
  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.strip
    next if line.empty?
    line = line.sub(/^\[[^\]]+\]\s*/, "")      # [timestamp] を除去
    cols = line.split("|").map(&:strip)
    no = cols[0].to_i
    next unless no >= 1 && no <= 100

    word    = cols[1] || ""
    season  = cols[3] || ""
    bui_str = cols[4] || ""
    bui     = bui_str.split(",").map(&:strip).reject(&:empty?)
    verses[no] = { word: word, season: season, bui: bui }
  end
  (1..100).each { |n| verses[n] ||= { word: "", season: "", bui: [] } }
  verses
end

# ---------------------------------------------------------------------------
# Jaccard 距離（measure_bui_distance.rb と同実装）
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
# 統計表示
# ---------------------------------------------------------------------------
def print_stats_block(label, dists)
  n = dists.size
  return puts "  (データなし)" if n == 0
  mean    = dists.sum / n.to_f
  sorted  = dists.sort
  median  = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  std_dev = Math.sqrt(dists.sum { |d| (d - mean)**2 } / n.to_f)
  puts "  #{label} (n=#{n})"
  puts "  最小値: #{format("%.6f", dists.min)}  最大値: #{format("%.6f", dists.max)}"
  puts "  平均値: #{format("%.6f", mean)}  中央値: #{format("%.6f", median)}  標準偏差: #{format("%.6f", std_dev)}"
  puts "  距離=0.0: #{dists.count(0.0)}ペア / 距離=1.0: #{dists.count(1.0)}ペア"
end

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
if ARGV.empty?
  puts "使い方: ruby #{$PROGRAM_NAME} LOG1 [LOG2 ...]"
  puts ""
  puts "例:"
  puts "  ruby script/measure_mentamu_bui_distance_from_log.rb \\"
  puts "    log/observe_rg_20260919_run1.log log/observe_rg_20260919.log"
  exit 0
end

all_csv_rows = []
baseline_label = "水無瀬三吟"
baseline = { mean: 0.794613, median: 1.000000, std_dev: 0.323142,
             dist_zero: 10, dist_one: 54, bui_present: 100 }

ARGV.each do |log_path|
  unless File.exist?(log_path)
    warn "ログファイルが見つかりません: #{log_path}"
    next
  end

  label  = File.basename(log_path, ".*")
  verses = parse_log_file(log_path)

  bui_present = (1..100).count { |n| !verses[n][:bui].empty? }

  distances = (1..99).map { |i|
    bui_jaccard_distance(verses[i][:bui], verses[i + 1][:bui]).round(6)
  }
  accels = calculate_acceleration(distances)

  # ペア分類
  type_a = (1..99).select { |i| !verses[i][:bui].empty? && !verses[i + 1][:bui].empty? }
  type_b = (1..99).select { |i| verses[i][:bui].empty? ^ verses[i + 1][:bui].empty? }
  type_c = (1..99).select { |i| verses[i][:bui].empty? && verses[i + 1][:bui].empty? }

  dists_a = type_a.map { |i| distances[i - 1] }

  puts ""
  puts "=== #{label} ==="
  puts "bui有り句数  : #{bui_present}/100"
  puts "Type A (両句bui有り) : #{type_a.size}ペア"
  puts "Type B (片句bui有り) : #{type_b.size}ペア  ← 距離=1.0確定"
  puts "Type C (両句bui無し) : #{type_c.size}ペア  ← 部立比較不能"
  puts ""
  puts "── 全99ペア（Type C を距離=1.0として計上） ──"
  print_stats_block("全体", distances)
  puts ""
  puts "── Type A のみ（有意距離ペア） ──"
  print_stats_block("Type A", dists_a)

  # CSV行
  (1..99).each do |i|
    type = if !verses[i][:bui].empty? && !verses[i + 1][:bui].empty?
             "A"
           elsif verses[i][:bui].empty? && verses[i + 1][:bui].empty?
             "C"
           else
             "B"
           end
    all_csv_rows << {
      log:          label,
      pair_no:      i,
      maeku_no:     i,
      maeku_word:   verses[i][:word],
      maeku_season: verses[i][:season],
      maeku_bui:    verses[i][:bui].join("・"),
      tsugeku_no:   i + 1,
      tsugeku_word: verses[i + 1][:word],
      tsugeku_season: verses[i + 1][:season],
      tsugeku_bui:  verses[i + 1][:bui].join("・"),
      bui_distance: distances[i - 1],
      acceleration: accels[i - 1],
      pair_type:    type
    }
  end
end

# 水無瀬三吟との比較
puts ""
puts "=== 水無瀬三吟 参考値（比較用） ==="
puts "bui有り句数  : #{baseline[:bui_present]}/100"
puts "Type A       : 99ペア（全句bui有りのため）"
puts "平均値       : #{format("%.6f", baseline[:mean])}"
puts "中央値       : #{format("%.6f", baseline[:median])}"
puts "標準偏差     : #{format("%.6f", baseline[:std_dev])}"
puts "距離=0.0     : #{baseline[:dist_zero]}ペア / 距離=1.0: #{baseline[:dist_one]}ペア"

# CSV出力
unless all_csv_rows.empty?
  csv_dir  = File.expand_path("../tmp", __dir__)
  Dir.mkdir(csv_dir) unless Dir.exist?(csv_dir)
  csv_path = File.join(csv_dir, "mentamu_bui_distance_from_log_report.csv")
  CSV.open(csv_path, "w", encoding: "UTF-8") do |csv|
    csv << %w[log pair_no maeku_no maeku_word maeku_season maeku_bui
              tsugeku_no tsugeku_word tsugeku_season tsugeku_bui
              bui_distance acceleration pair_type]
    all_csv_rows.each { |r| csv << r.values }
  end
  puts ""
  puts "CSV出力: #{csv_path}"
end
