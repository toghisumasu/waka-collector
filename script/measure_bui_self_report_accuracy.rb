#!/usr/bin/env ruby
# frozen_string_literal: true

# measure_bui_self_report_accuracy.rb — bui自己申告の正規カテゴリ一致率測定（其の三十三）
#
# dryrun_hyakuin.rb が generation_attempts.log に残す candidate.raw_bui
# （正規化前のLLM自己申告そのまま、其の二十八）を、dryrun_hyakuin.rb が
# 実際に使っている valid_bui_categories（ShikimokuChecker.rules.keys + 時分/人倫）
# と照合し、「LLMの自己申告が最初から正規カテゴリ名そのものだった率」を算出する。
#
# 一致の定義: 候補（1 attempt）ごとに、raw_bui配列が非空かつ全要素が
# valid_bui_categories に含まれる場合を「完全一致」とする（1要素でも
# 正規カテゴリ外、または空配列の場合は不一致）。
#
# 使用法:
#   bundle exec ruby script/measure_bui_self_report_accuracy.rb
#   bundle exec ruby script/measure_bui_self_report_accuracy.rb --from "2026-07-08 08:00:00" --to "2026-07-08 09:00:00"
#   bundle exec ruby script/measure_bui_self_report_accuracy.rb --log log/generation_attempts.log

require "json"
require_relative "../app/services/shikimoku_checker"

LOG_DIR      = File.expand_path("../log", __dir__)
DEFAULT_LOG  = File.join(LOG_DIR, "generation_attempts.log")

# ─────────────────────────────────────────────────────────────
#  引数解析
# ─────────────────────────────────────────────────────────────

options = { log: DEFAULT_LOG, from: nil, to: nil }
args = ARGV.dup
until args.empty?
  case args.shift
  when "--from" then options[:from] = args.shift
  when "--to"   then options[:to]   = args.shift
  when "--log"  then options[:log]  = File.expand_path(args.shift, File.expand_path("..", __dir__))
  end
end

# ─────────────────────────────────────────────────────────────
#  valid_bui_categories — dryrun_hyakuin.rb と同一の算出方法
# ─────────────────────────────────────────────────────────────

checker = ShikimokuChecker.new
VALID_BUI_CATEGORIES = (checker.rules.keys + %w[時分 人倫]).uniq.freeze

# ─────────────────────────────────────────────────────────────
#  集計
# ─────────────────────────────────────────────────────────────

total_candidates = 0
full_match       = 0
invalid_tag_counts = Hash.new(0)

File.foreach(options[:log]) do |line|
  entry = begin
    JSON.parse(line)
  rescue JSON::ParserError
    next
  end

  ts = entry["ts"]
  next if options[:from] && ts && ts < options[:from]
  next if options[:to]   && ts && ts > options[:to]

  candidate = entry["candidate"]
  next if candidate.nil?

  raw_bui = candidate["raw_bui"]
  next if raw_bui.nil? # 其の二十八以前のログにはraw_bui自体が存在しない

  total_candidates += 1

  if raw_bui.empty?
    invalid_tag_counts["(空配列)"] += 1
    next
  end

  if raw_bui.all? { |t| VALID_BUI_CATEGORIES.include?(t) }
    full_match += 1
  else
    raw_bui.reject { |t| VALID_BUI_CATEGORIES.include?(t) }.each { |t| invalid_tag_counts[t] += 1 }
  end
end

# ─────────────────────────────────────────────────────────────
#  出力
# ─────────────────────────────────────────────────────────────

puts "=" * 60
puts "bui自己申告 正規カテゴリ一致率測定"
puts "=" * 60
puts "対象ログ: #{options[:log]}"
puts "期間: #{options[:from] || '(指定なし)'} 〜 #{options[:to] || '(指定なし)'}"
puts "正規カテゴリ(#{VALID_BUI_CATEGORIES.size}件): #{VALID_BUI_CATEGORIES.join('・')}"
puts "-" * 60

if total_candidates.zero?
  puts "対象候補が0件でした（期間指定・raw_bui有無を確認してください）"
  exit 0
end

rate = (full_match.to_f / total_candidates * 100).round(1)
puts "総候補数　　: #{total_candidates}"
puts "完全一致数　: #{full_match}"
puts "一致率　　　: #{rate}%"
puts "-" * 60
puts "不一致パターン 上位10件（正規カテゴリ外のbui自己申告値）:"
invalid_tag_counts.sort_by { |_tag, count| -count }.first(10).each do |tag, count|
  puts "  #{tag}: #{count}件"
end
puts "=" * 60
