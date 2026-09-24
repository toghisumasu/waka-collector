# frozen_string_literal: true
# G-2: bui辞書一括追記スクリプト
#
# 使い方:
#   bin/rails runner script/add_bui_entries.rb -- --dry-run   # 追加予定を標準出力のみ
#   bin/rails runner script/add_bui_entries.rb                # 実際に追記
#
# G-1・Nobuson精査（依頼書 irai_g2_add_bui_entries.md §1）で確定した57語を
# app/data/bui_dictionary.ymlへ追記する。既存エントリは変更しない
# （上書きではなく末尾追記、既存コメント行もそのまま残る）。
# 既存キーと重複する語が見つかった場合はスキップし警告するのみ（既存優先）。
# MeCabは使用しない（辞書への直接追記のみ、依頼書の不変条件）。

require "yaml"

DICT_PATH = Rails.root.join("app", "data", "bui_dictionary.yml")
DRY_RUN   = ARGV.include?("--dry-run")

# 依頼書§1のNobuson精査済みエントリ一覧（記載順のまま）。
ENTRIES = [
  # --- 植物（plant_type付き） ---
  ["もみじ",     { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "tree",  note: "(漢字: 紅葉と同一)" }],
  ["すすき",     { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "grass", note: "(漢字: 薄と同一)" }],
  ["わらび",     { primary_bui: "植物", season: "春", taiyo: "体", plant_type: "grass" }],
  ["おみなえし", { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "flower" }],
  ["すみれ",     { primary_bui: "植物", season: "春", taiyo: "体", plant_type: "flower" }],
  ["むくげ",     { primary_bui: "植物", season: "夏", taiyo: "体", plant_type: "flower" }],
  ["山吹",       { primary_bui: "植物", season: "春", taiyo: "体", plant_type: "flower" }],
  ["桃",         { primary_bui: "植物", season: "春", taiyo: "体", plant_type: "flower" }],
  ["菜の花",     { primary_bui: "植物", season: "春", taiyo: "体", plant_type: "flower" }],
  ["菊",         { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "flower" }],
  ["葉",         { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "tree" }],
  ["木の葉",     { primary_bui: "植物", season: "秋", taiyo: "体", plant_type: "tree" }],
  ["木々",       { primary_bui: "植物", season: nil,  taiyo: "体", plant_type: "tree" }],
  ["梢",         { primary_bui: "植物", season: nil,  taiyo: "体", plant_type: "tree" }],
  ["枯枝",       { primary_bui: "植物", season: "冬", taiyo: "体", plant_type: "tree" }],

  # --- 動物 ---
  ["千鳥",   { primary_bui: "動物", season: "冬", taiyo: "体" }],
  ["蝶",     { primary_bui: "動物", season: "春", taiyo: "体" }],
  ["蛙",     { primary_bui: "動物", season: "春", taiyo: "体" }],
  ["雁",     { primary_bui: "動物", season: "秋", taiyo: "体", note: "帰雁（春）は既存エントリあり。雁は秋として独立登録" }],
  ["鷺",     { primary_bui: "動物", season: nil,  taiyo: "体" }],
  ["うぐいす", { primary_bui: "動物", season: "春", taiyo: "体" }],

  # --- 降物 ---
  ["しぐれ", { primary_bui: "降物", season: "冬", taiyo: "体", note: "(漢字: 時雨と同一)" }],
  ["露",     { primary_bui: "降物", season: "秋", taiyo: "体" }],
  ["雪",     { primary_bui: "降物", season: "冬", taiyo: "体" }],
  ["雨",     { primary_bui: "降物", season: nil,  taiyo: "体" }],
  ["滴",     { primary_bui: "降物", season: nil,  taiyo: "体" }],
  ["氷",     { primary_bui: "降物", season: "冬", taiyo: "体" }],
  ["みぞれ", { primary_bui: "降物", season: "冬", taiyo: "体", note: "MeCabで「みぞ」に分割される場合あり（run4 058/070句確認済み）" }],

  # --- 聳物 ---
  ["霞", { primary_bui: "聳物", season: "春", taiyo: "体" }],
  ["風", { primary_bui: "聳物", season: nil,  taiyo: "体" }],
  ["嵐", { primary_bui: "聳物", season: "秋", taiyo: "体" }],
  ["きり", { primary_bui: "聳物", season: "秋", taiyo: "体", note: "(漢字: 霧)" }],
  ["空", { primary_bui: "聳物", season: nil,  taiyo: "体", note: "「そら」読み。くう（仏教）は釈教だが、メンタムさんの用法はそら" }],

  # --- 光物 ---
  ["光", { primary_bui: "光物", season: nil,  taiyo: "体" }],
  ["影", { primary_bui: "光物", season: nil,  taiyo: "体" }],
  ["灯", { primary_bui: "光物", season: nil,  taiyo: "体" }],
  ["朧", { primary_bui: "光物", season: "春", taiyo: "体" }],

  # --- 水辺 ---
  ["波",   { primary_bui: "水辺", season: nil, taiyo: "体" }],
  ["浜辺", { primary_bui: "水辺", season: nil, taiyo: "体" }],
  ["潮",   { primary_bui: "水辺", season: nil, taiyo: "体" }],
  ["海",   { primary_bui: "水辺", season: nil, taiyo: "体" }],
  ["川",   { primary_bui: "水辺", season: nil, taiyo: "体" }],
  ["古池", { primary_bui: "水辺", season: nil, taiyo: "体" }],

  # --- 時分 ---
  ["時",     { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["朝",     { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["未明",   { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["夜",     { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["夕暮れ", { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["黄昏",   { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["宵",     { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["明け方", { primary_bui: "時分", season: nil, taiyo: "体" }],
  ["暁",     { primary_bui: "時分", season: nil, taiyo: "体" }],

  # --- 居所 ---
  ["庭", { primary_bui: "居所", season: nil, taiyo: "体" }],

  # --- 釈教 ---
  ["寺",   { primary_bui: "釈教", season: nil, taiyo: "体" }],
  ["仏前", { primary_bui: "釈教", season: nil, taiyo: "体" }],

  # --- 名所 ---
  ["竜田", { primary_bui: "名所", season: "秋", taiyo: "体", note: "竜田川・竜田山（紅葉の名所）" }],

  # --- 人倫 ---
  ["心", { primary_bui: "人倫", season: nil, taiyo: "体" }],
].freeze

existing_keys = YAML.load_file(DICT_PATH).keys.to_set

to_add = []
skipped = []
ENTRIES.each do |word, attrs|
  if existing_keys.include?(word)
    skipped << word
  else
    to_add << [word, attrs]
  end
end

def format_entry(word, attrs)
  lines = ["#{word}:"]
  lines << "  primary_bui: #{attrs[:primary_bui]}"
  lines << "  season: #{attrs[:season] || 'null'}"
  lines << "  taiyo: #{attrs[:taiyo]}"
  lines << "  plant_type: #{attrs[:plant_type]}" if attrs[:plant_type]
  lines << "  note: \"#{attrs[:note]}\"" if attrs[:note]
  lines.join("\n")
end

block = +"\n# ── G-2追記 2026-09-24：run4語彙抽出・辞書充実（bui未登録語#{to_add.size}語） ──\n"
to_add.each { |word, attrs| block << "#{format_entry(word, attrs)}\n\n" }

puts "追加予定: #{to_add.size}語"
puts "スキップ（既存キーと重複）: #{skipped.size}語#{skipped.empty? ? '' : " (#{skipped.join(', ')})"}"

if DRY_RUN
  puts "--- dry-run: 実際の書き込みは行いません ---"
  puts block
else
  File.open(DICT_PATH, "a") { |f| f.write(block) }
  puts "書き込み完了: #{DICT_PATH}"
end
