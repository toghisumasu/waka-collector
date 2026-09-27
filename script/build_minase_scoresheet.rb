# frozen_string_literal: true
# 依頼書M-4 Phase1: 水無瀬三吟 模範スコアシート統合
#
# script/measure_minase_distance.rb（語彙非重複率）と
# script/measure_bui_distance.rb（bui Jaccard距離、人手注釈bui使用）の
# 出力を1本のCSVに統合し、新しい前句・付句ペアの機械的な照合を
# 可能にする。
#
# Phase0で判明した重大事項（人間承認済み・方向性(a)の変形）:
#   docs/minase_sangin_hyakuin.md の人手注釈bui（「主な部立」列）は
#   100句全てに存在しN/A 0件だが、BuiDictionary#detect_allでは
#   100句中55句が空集合を返し、99ペア中73ペアがN/A化する
#   （折別では名残折裏が7/7件全てN/A）。したがってbui距離を
#   hand（人手注釈・overview.md目標値との照合用）とauto（機械検出・
#   新規句照合用）の2系統に分離する。新しい句には人手注釈が
#   存在しないため、将来の照合は必ずauto版と比較すること。
#
# 列構成:
#   pair_no            前句の絶対句番（1〜99）
#   ori                折（初折表〜名残折裏、8区分の結合ラベル）
#   maeku_text         前句本文
#   tsukeku_text       付句本文
#   overlap            語彙非重複率（1.0に近いほど独立。
#                      script/measure_minase_distance.rbのnon_overlap_rate
#                      をそのまま採用した名称であり、script/analyze_
#                      compare_models.rb（M-2）の"overlap"列＝重複率とは
#                      定義が逆であることに注意。混同禁止）
#   maeku_bui_hand     前句のbui（docs/minase_sangin_hyakuin.md人手注釈）
#   maeku_bui_auto     前句のbui（BuiDictionary#detect_all）
#   tsukeku_bui_hand   付句のbui（人手注釈）
#   tsukeku_bui_auto   付句のbui（BuiDictionary#detect_all）
#   bui_distance_hand  bui Jaccard距離（hand。N/A 0件。RC-3判定対象）
#   bui_distance_auto  bui Jaccard距離（auto。前句または付句が空集合の
#                      場合は空欄＝N/A。参考値、一致は求めない）
#   bui_na             bui_distance_autoがN/Aかどうか（true/false。
#                      hand版は常にfalseなので専用列は設けない）
#
# 実行: bin/rails runner script/build_minase_scoresheet.rb
# 出力: tmp/minase_scoresheet.csv（固定データのためコミット対象）
# app/配下は無変更。DB書き込みなし。既存2スクリプト本体は無変更。

require "csv"
require "natto"

CONTENT_POS_IPADIC = %w[名詞 動詞 形容詞 副詞].freeze

FOLD_MAP = [
  { range: (1..8),   ori: "初折表" },
  { range: (9..22),  ori: "初折裏" },
  { range: (23..36), ori: "二折表" },
  { range: (37..50), ori: "二折裏" },
  { range: (51..64), ori: "三折表" },
  { range: (65..78), ori: "三折裏" },
  { range: (79..92), ori: "名残折表" },
  { range: (93..99), ori: "名残折裏" },
].freeze
def fold_of(maeku_no)
  (FOLD_MAP.find { |f| f[:range].include?(maeku_no) } || {})[:ori] || "不明"
end

# docs/distance evaluation design.md §5.2（RC-3判定基準。今回は変更しない）。
FOLD_TARGET_DISTANCE = {
  "初折表"   => 0.750,
  "初折裏"   => 0.792,
  "二折表"   => 0.833,
  "二折裏"   => 0.887,
  "三折表"   => 0.875,
  "三折裏"   => 0.714,
  "名残折表" => 0.750,
  "名残折裏" => 0.679
}.freeze
RC3_TOLERANCE = 0.001

# script/measure_bui_distance.rbと同一の式。
def bui_jaccard_distance(set_a, set_b)
  return 1.0 if set_a.empty? && set_b.empty?
  intersection = (set_a & set_b).size
  union = (set_a | set_b).size
  1.0 - intersection.to_f / union
end

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end

# script/measure_minase_distance.rbと同一の内容語抽出方式。
NM = build_mecab
EXTRACT_WORDS =
  if defined?(WakaUnidicAnalyzer) && WakaUnidicAnalyzer.available?
    analyzer = WakaUnidicAnalyzer.new
    ->(text) {
      analyzer.analyze(text).select { |m| CONTENT_POS_IPADIC.any? { |pos| m.pos.start_with?(pos) } }.map(&:surface)
    }
  else
    ->(text) {
      words = []
      NM.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
        next if node.is_eos? || node.surface.empty?
        pos = node.feature.split(",").first
        words << node.surface if CONTENT_POS_IPADIC.include?(pos)
      end
      words
    }
  end

def non_overlap_rate(maeku_text, tsukeku_text)
  a = EXTRACT_WORDS.call(maeku_text)
  b = EXTRACT_WORDS.call(tsukeku_text)
  shared = (a & b).uniq
  union  = (a | b).uniq
  union.empty? ? 1.0 : 1.0 - (shared.size.to_f / union.size)
end

# ─────────────────────────────────────────────────────────
# docs/minase_sangin_hyakuin.md から100句・人手注釈buiを読み込む
# （script/measure_bui_distance.rbと同一のパース処理）
# ─────────────────────────────────────────────────────────
md_path = Rails.root.join("docs", "minase_sangin_hyakuin.md")
verses = []
File.foreach(md_path) do |line|
  next unless line.start_with?("|")
  cols = line.split("|").map(&:strip)
  next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
  verse_no = cols[1].to_i
  next unless verse_no >= 1 && verse_no <= 100
  text = cols[4]
  next if text.nil? || text.empty?

  bui_raw = cols[6] || ""
  bui_hand = bui_raw.split("・").map { |b| b.gsub(/（[^）]*）/, "").strip }.reject(&:empty?)

  verses << { no: verse_no, text: text, bui_hand: bui_hand }
end
verses.sort_by! { |v| v[:no] }
raise "水無瀬三吟100句が読み込めません（#{verses.size}句）" unless verses.size == 100

bui_dict = BuiDictionary.new
verses.each { |v| v[:bui_auto] = bui_dict.detect_all(v[:text], NM) }

# ─────────────────────────────────────────────────────────
# 99ペアの算出
# ─────────────────────────────────────────────────────────
rows = []
(0..98).each do |i|
  maeku   = verses[i]
  tsukeku = verses[i + 1]

  bui_na = maeku[:bui_auto].empty? || tsukeku[:bui_auto].empty?
  bui_distance_auto = bui_na ? nil : bui_jaccard_distance(maeku[:bui_auto], tsukeku[:bui_auto]).round(6)

  rows << {
    pair_no:           maeku[:no],
    ori:               fold_of(maeku[:no]),
    maeku_text:        maeku[:text],
    tsukeku_text:      tsukeku[:text],
    overlap:           non_overlap_rate(maeku[:text], tsukeku[:text]).round(6),
    maeku_bui_hand:    maeku[:bui_hand].join("・"),
    maeku_bui_auto:    maeku[:bui_auto].join("・"),
    tsukeku_bui_hand:  tsukeku[:bui_hand].join("・"),
    tsukeku_bui_auto:  tsukeku[:bui_auto].join("・"),
    bui_distance_hand: bui_jaccard_distance(maeku[:bui_hand], tsukeku[:bui_hand]).round(6),
    bui_distance_auto: bui_distance_auto,
    bui_na:            bui_na
  }
end

# ─────────────────────────────────────────────────────────
# 出力
# ─────────────────────────────────────────────────────────
out_path = Rails.root.join("tmp", "minase_scoresheet.csv")
headers = %i[pair_no ori maeku_text tsukeku_text overlap maeku_bui_hand maeku_bui_auto
             tsukeku_bui_hand tsukeku_bui_auto bui_distance_hand bui_distance_auto bui_na]
CSV.open(out_path, "w") do |csv|
  csv << headers
  rows.each { |r| csv << r.values_at(*headers) }
end
puts "出力: #{out_path}（#{rows.size}行）"

# ─────────────────────────────────────────────────────────
# 集計サマリ
# ─────────────────────────────────────────────────────────
def stats(values)
  n = values.size
  return { n: 0 } if n.zero?

  sorted = values.sort
  mean   = values.sum / n.to_f
  median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  { n: n, mean: mean, median: median, min: values.min, max: values.max }
end

puts "\n" + "=" * 70
puts "【全体】"
ov = stats(rows.map { |r| r[:overlap] })
puts "  overlap: n=#{ov[:n]} 平均=#{ov[:mean].round(4)} 中央値=#{ov[:median].round(4)} 最小=#{ov[:min].round(4)}"

hd = stats(rows.map { |r| r[:bui_distance_hand] })
puts "  bui_distance_hand: n=#{hd[:n]} 平均=#{hd[:mean].round(4)} 中央値=#{hd[:median].round(4)}"

auto_vals = rows.reject { |r| r[:bui_na] }.map { |r| r[:bui_distance_auto] }
na_count  = rows.count { |r| r[:bui_na] }
if auto_vals.any?
  ad = stats(auto_vals)
  puts "  bui_distance_auto: n=#{ad[:n]}（N/A #{na_count}件除外） 平均=#{ad[:mean].round(4)} 中央値=#{ad[:median].round(4)}"
else
  puts "  bui_distance_auto: 有効データなし（N/A #{na_count}件）"
end

puts "\n【折別】overlap平均 / bui_distance_hand平均（RC-3判定） / bui_distance_auto平均（参考、N/A件数）"
rc3_all_pass = true
FOLD_TARGET_DISTANCE.each_key do |fold|
  group = rows.select { |r| r[:ori] == fold }
  next if group.empty?

  ov_avg = group.sum { |r| r[:overlap] } / group.size.to_f
  hd_avg = group.sum { |r| r[:bui_distance_hand] } / group.size.to_f
  target = FOLD_TARGET_DISTANCE[fold]
  diff   = (hd_avg - target).abs
  pass   = diff <= RC3_TOLERANCE
  rc3_all_pass &&= pass

  auto_group = group.reject { |r| r[:bui_na] }
  auto_str =
    if auto_group.any?
      auto_avg = auto_group.sum { |r| r[:bui_distance_auto] } / auto_group.size.to_f
      "auto平均=#{auto_avg.round(4)}(n=#{auto_group.size}/#{group.size})"
    else
      "auto平均=算出不可(有効ペア0件/#{group.size})"
    end

  puts "  #{fold} (n=#{group.size}): overlap=#{ov_avg.round(4)} " \
       "hand=#{hd_avg.round(6)} target=#{target} diff=#{diff.round(6)} #{pass ? 'PASS' : 'FAIL'} | #{auto_str}"
end

puts "\n【RC-3判定】bui_distance_hand 折別平均 vs overview.md(docs/distance evaluation design.md)8値: " \
     "#{rc3_all_pass ? 'PASS（全折一致）' : 'FAIL（不一致あり、上記参照）'}"

puts "\n【bui_na内訳（auto版のみ、参考）】"
puts "  該当ペア数: #{na_count}/#{rows.size}"
na_maeku_nos = rows.select { |r| r[:bui_na] }.map { |r| r[:pair_no] }
empty_verses = verses.select { |v| v[:bui_auto].empty? }
puts "  bui_auto空集合の句: #{empty_verses.size}/100句"
puts "  （句番一覧: #{empty_verses.map { |v| v[:no] }.join(',')}）"
