# frozen_string_literal: true
# G-3: bui辞書一括追記スクリプト（聳物・鳥類・釈教の補完）
#
# 使い方:
#   bin/rails runner script/add_bui_entries_g3.rb -- --dry-run   # 追加予定を標準出力のみ
#   bin/rails runner script/add_bui_entries_g3.rb                # 実際に追記
#
# 別プロジェクト（Nobuson運用のClaude.aiプロジェクト、G-3提案12語）で
# 精査された語彙のうち、本リポジトリのbui_dictionary.ymlに未登録の語のみを
# 追記する。G-3提案の12語中、霞・雁・千鳥はG-2（commit 24c591f）で既に
# 登録済みだったため対象から除外し、残り9語のみをここに定義する。
# 既存エントリは変更しない（上書きではなく末尾追記）。
# 既存キーと重複する語が見つかった場合はスキップし警告するのみ（既存優先）。
# MeCabは使用しない（辞書への直接追記のみ、G-1/G-2の不変条件を踏襲）。

require "yaml"
require "set"

DICT_PATH = Rails.root.join("app", "data", "bui_dictionary.yml")
DRY_RUN   = ARGV.include?("--dry-run")

# G-3提案12語のうち、既存登録済み(霞・雁・千鳥、G-2で追加済み)を除いた9語。
ENTRIES = [
  # --- 聳物 ---
  ["霧", { primary_bui: "聳物", season: "秋", taiyo: "体" }],
  ["雲", { primary_bui: "聳物", season: nil,  taiyo: "体" }],

  # --- 動物（鳥類） ---
  ["鶯",     { primary_bui: "動物", season: "春", taiyo: "体" }],
  ["郭公",   { primary_bui: "動物", season: "夏", taiyo: "体" }],
  ["時鳥",   { primary_bui: "動物", season: "夏", taiyo: "体" }],
  ["鶴",     { primary_bui: "動物", season: nil,  taiyo: "体" }],
  ["喚子鳥", { primary_bui: "動物", season: "春", taiyo: "体" }],
  ["たつ",   { primary_bui: "動物", season: nil,  taiyo: "体" }],

  # --- 釈教 ---
  ["鐘", { primary_bui: "釈教", season: nil, taiyo: "体" }],
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

block = +"\n# ── G-3追記 2026-09-25：聳物・鳥類・釈教の補完（bui未登録語#{to_add.size}語） ──\n"
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
