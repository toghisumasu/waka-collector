# frozen_string_literal: true

# analyze_sono41.rb — 其の四十一：observation_sono39系ログのng却下頻度・
# 違反種別分布を集計する読み取り専用スクリプト（生成ロジック・DBには触れない）。
#
# 使い方: ruby script/analyze_sono41.rb log/observation_sono39_run5_20260716.jsonl

require "json"

path  = ARGV[0] or abort "使い方: ruby script/analyze_sono41.rb <jsonlパス>"
lines = File.readlines(path).map { |l| JSON.parse(l, symbolize_names: true) }

seed_lines    = lines.select { |l| l[:action] == "seed" }
attempt_lines = lines.reject { |l| l[:action] == "seed" }

max_verse = lines.map { |l| l[:verse_no] }.max

puts "=== 基本情報 ==="
puts "総行数: #{lines.size}（seed: #{seed_lines.size} / attempt: #{attempt_lines.size}）"
puts "最終verse_no: #{max_verse}"
puts

# --- attempt行を排他的に分類 ---
# 生成失敗・モーラng・式目ng・forced_zatsu系・create の5系統に分ける。
# 字数ng（モーラng）と式目ng（ShikimokuChecker由来）は必ず分離する。
category_of = lambda do |l|
  case l[:action]
  when "create"                                then :create
  when "forced_zatsu", "forced_zatsu_create"    then :forced_zatsu_progress
  when "forced_zatsu_mora_ng"                   then :forced_zatsu_mora_ng
  when "maeku_ng_continue"                       then :maeku_ng_continue
  else
    if l[:violations]&.any? { |v| v == "生成失敗" }
      :generate_fail
    elsif l[:violations]&.any? { |v| v.to_s.start_with?("モーラng") }
      :mora_ng
    elsif l[:violations]&.any? { |v| v.to_s.include?("接続エラー") || v.to_s.include?("タイムアウト") }
      :connection_error
    elsif l[:shikimoku_result] == "ng"
      :shikimoku_ng
    else
      :other
    end
  end
end

categories = attempt_lines.group_by { |l| category_of.call(l) }

puts "=== attempt行の排他的分類 ==="
categories.sort_by { |_, v| -v.size }.each do |cat, rows|
  pct = (rows.size.to_f / attempt_lines.size * 100).round(1)
  puts "  #{cat}: #{rows.size} (#{pct}%)"
end
puts

# --- ng却下頻度（生成ロジック本体の主ループでの却下。forced_zatsu系は除く） ---
primary_ng = attempt_lines.select { |l| %w[retry exhausted].include?(l[:action]) }
primary_ok = attempt_lines.select { |l| l[:action] == "create" }
puts "=== ng却下頻度（主ループのみ、forced_zatsu系除く） ==="
puts "主ループ試行数: #{primary_ng.size + primary_ok.size}"
puts "ng却下: #{primary_ng.size} (#{(primary_ng.size.to_f / (primary_ng.size + primary_ok.size) * 100).round(1)}%)"
puts

# --- verse単位: 何句がforced_zatsuにエスカレーションしたか ---
fz_verses = attempt_lines.select { |l| l[:action].to_s.start_with?("forced_zatsu") }.map { |l| l[:verse_no] }.uniq.sort
puts "=== forced_zatsuエスカレーション ==="
puts "発動verse: #{fz_verses} (#{fz_verses.size}/#{max_verse}句 = #{(fz_verses.size.to_f / max_verse * 100).round(1)}%)"
puts

# --- 式目ng違反の種別内訳（category:detail のcategory部分で集計） ---
shikimoku_violation_counts = Hash.new(0)
attempt_lines.each do |l|
  next unless l[:shikimoku_result] == "ng"

  l[:violations].each do |v|
    cat = v.to_s.split(":").first
    shikimoku_violation_counts[cat] += 1
  end
end
puts "=== 式目ng違反の種別内訳（字数ngは含まない） ==="
shikimoku_violation_counts.sort_by { |_, c| -c }.each { |cat, c| puts "  #{cat}: #{c}" }
puts

# --- モーラng（字数ng）の内訳（音数） ---
mora_ng_details = attempt_lines.select { |l| l[:violations]&.any? { |v| v.to_s.start_with?("モーラng") } }
                                .flat_map { |l| l[:violations] }
                                .select { |v| v.to_s.start_with?("モーラng") }
puts "=== モーラng（字数ng）件数 ==="
puts "  合計: #{mora_ng_details.size}"
puts

# --- verse_no別の試行回数（局面打開の重さの分布） ---
attempts_per_verse = attempt_lines.group_by { |l| l[:verse_no] }.transform_values(&:size)
puts "=== verse別試行回数 上位10 ==="
attempts_per_verse.sort_by { |_, c| -c }.first(10).each { |vn, c| puts "  verse #{vn}: #{c}回" }
