#!/usr/bin/env ruby
# frozen_string_literal: true

# analyze_deflock_mora.rb — 二山・deflock Phase0調査（依頼書_deflock_phase0.md §2）
#
# StepwiseWakaGenerator（:waka_extraction）のStep3⇄Step4往復について、
# log/stepwise_steps_*.jsonl（StepwiseStepLoggerの恒常ログ）から
# observation_batch = 'sono76_mcflag_p1_run100_20260901' のレコードを抽出し、
# mora分布・deflock率・Step3呼出理由の内訳を集計する。
#
# 注意: この観測データはDBではなくlog/*.jsonl（ファイル）にのみ存在する
# （rengasテーブルのobservation_batchは最終採用句のみでStep単位の記録は無い）。
# 本スクリプトはファイルの読み取りのみを行い、DBへの接続・書き込みは行わない。
#
# 使用法:
#   bundle exec ruby script/analyze_deflock_mora.rb [batch名]
# （省略時は既定で sono76_mcflag_p1_run100_20260901 を対象とする）

require "json"

LOG_DIR = File.expand_path("../log", __dir__)
BATCH   = ARGV[0] || "sono76_mcflag_p1_run100_20260901"

def load_records(batch)
  records = []
  Dir.glob(File.join(LOG_DIR, "stepwise_steps_*.jsonl")).sort.each do |path|
    File.foreach(path) do |line|
      next unless line.include?(batch)

      rec = JSON.parse(line, symbolize_names: true)
      records << rec if rec[:batch] == batch
    end
  end
  records
end

def histogram(values, buckets)
  counts = Hash.new(0)
  values.each do |v|
    label = buckets.find { |_, range| range.cover?(v) }&.first || "範囲外(#{v})"
    counts[label] += 1
  end
  buckets.each { |label, _| counts[label] ||= 0 }
  counts
end

def print_histogram(counts, order, total)
  order.each do |label|
    n = counts[label] || 0
    pct = total.positive? ? (100.0 * n / total).round(1) : 0.0
    puts format("  %-14s %4d件  %5.1f%%", label, n, pct)
  end
end

MORA_BUCKETS = [
  ["<25",    (0...25)],
  ["25-28",  (25...29)],
  ["29-33(適正)", (29..33)],
  ["34-37",  (34..37)],
  ["38-41",  (38..41)],
  ["42-49",  (42..49)],
  ["50+",    (50..Float::INFINITY)],
].freeze
MORA_ORDER = MORA_BUCKETS.map(&:first)

def classify_feedback_issue(issue)
  return "なし（初回attempt）" if issue.nil?
  return "前句エコー" if issue == "前句エコー"
  return "句切れ不自然（境界の語破れ）" if issue == "句切れ不自然"
  return "区切り不一致（17音境界に語境界なし）" if issue == "区切り不一致"

  m = issue.match(/\A(\d+)音（三十一音から/)
  return "分類不能: #{issue}" unless m

  mora = m[1].to_i
  mora > 31 ? "too_long（超過）" : "too_short（不足）"
end

records = load_records(BATCH)
if records.empty?
  puts "対象レコードが見つかりません（batch=#{BATCH}）。log/stepwise_steps_*.jsonl を確認してください。"
  exit 1
end

step3 = records.select { |r| r[:step] == "step3" }
step4 = records.select { |r| r[:step] == "step4" }

puts "=" * 70
puts "二山・deflock Phase0 mora分布集計"
puts "batch = #{BATCH}"
puts "対象レコード数 = #{records.size}（step1:#{records.count { |r| r[:step] == 'step1' }} " \
     "step1.5:#{records.count { |r| r[:step] == 'step1.5' }} step2:#{records.count { |r| r[:step] == 'step2' }} " \
     "step3:#{step3.size} step4:#{step4.size}）"
puts "verse_no範囲 = #{records.map { |r| r[:verse_no] }.min}..#{records.map { |r| r[:verse_no] }.max}" \
     "（distinct #{records.map { |r| r[:verse_no] }.uniq.size}句）"
puts "=" * 70

# --- 1. rewrite_attempt別のmora分布（Step3入力時のfree_text mora数） ---
puts "\n## 1. rewrite_attempt別 mora分布（Step3入力＝free_text）"
puts "※ input_text は同一flow内では常に元のfree_text（書き換え対象は変わらない実装）のため、"
puts "  attempt間の差は「そのattemptまで生き残ったflowの母集団」の違いを表す（生存者バイアス）。"
(1..5).each do |att|
  vals = step3.select { |r| r[:rewrite_attempt] == att }.map { |r| r[:input_mora] }.compact
  next if vals.empty?

  mean = (vals.sum.to_f / vals.size).round(1)
  puts "\nattempt=#{att}  n=#{vals.size}  mean=#{mean}  min=#{vals.min}  max=#{vals.max}"
  print_histogram(histogram(vals, MORA_BUCKETS), MORA_ORDER, vals.size)
end

# --- 2. deflock句（rewrite_attempt=5到達）の最終出力mora分布 ---
puts "\n\n## 2. deflock句（rewrite_attempt=5到達）の最終Step3出力mora分布"
a5 = step3.select { |r| r[:rewrite_attempt] == 5 }
a5_vals = a5.map { |r| r[:output_mora] }.compact
puts "n=#{a5_vals.size}  mean=#{(a5_vals.sum.to_f / a5_vals.size).round(2)}  " \
     "min=#{a5_vals.min}  max=#{a5_vals.max}"
print_histogram(histogram(a5_vals, MORA_BUCKETS), MORA_ORDER, a5_vals.size)

a5_verdict = step4.select { |r| r[:rewrite_attempt] == 5 }
succ5 = a5_verdict.count { |r| r[:issue].nil? }
puts "\nattempt=5時点のstep4判定: n=#{a5_verdict.size}  成功(抽出)=#{succ5}  " \
     "失敗（draft attemptごと終了）=#{a5_verdict.size - succ5}"

# --- deflock率（attempt1母数に対するattempt5到達率） ---
a1_count = step3.count { |r| r[:rewrite_attempt] == 1 }
a5_count = step3.count { |r| r[:rewrite_attempt] == 5 }
deflock_rate = a1_count.positive? ? (100.0 * a5_count / a1_count).round(1) : 0.0
puts "\ndeflock率（attempt5到達 / attempt1総数） = #{a5_count}/#{a1_count} = #{deflock_rate}%"

# --- attempt別 step4成功率（Step3単体の命中率の内訳） ---
puts "\nattempt別 step4成功率（Step3書き換えがそのattemptで31音抽出に成功した割合）:"
(1..5).each do |att|
  grp = step4.select { |r| r[:rewrite_attempt] == att }
  next if grp.empty?

  succ = grp.count { |r| r[:issue].nil? }
  puts "  attempt=#{att}  n=#{grp.size}  成功=#{succ}  #{(100.0 * succ / grp.size).round(1)}%"
end
overall_step3_entered = step4.reject { |r| r[:step3_skipped] }
overall_succ = overall_step3_entered.count { |r| r[:issue].nil? }
puts "  全attempt合計（Step3経由のみ）  n=#{overall_step3_entered.size}  成功=#{overall_succ}  " \
     "#{(100.0 * overall_succ / overall_step3_entered.size).round(1)}%"

# --- 3. Step3呼出理由（too_long/too_short等）の内訳 ---
puts "\n\n## 3. Step3呼出理由の内訳（attempt2以降＝前回失敗のfeedback_issue由来）"
reasons = step3.select { |r| r[:rewrite_attempt] && r[:rewrite_attempt] >= 2 }
                .map { |r| classify_feedback_issue(r[:feedback_issue]) }
counts = reasons.tally
total = reasons.size
counts.sort_by { |_, v| -v }.each do |label, n|
  puts format("  %-32s %4d件  %5.1f%%", label, n, (100.0 * n / total).round(1))
end
puts "合計 n=#{total}"

# --- 4. Step3スキップ（案2発動）句のmora分布 ---
puts "\n\n## 4. Step3スキップ（案2 pre_seg発動）句のmora分布"
skipped = step4.select { |r| r[:step3_skipped] }
if skipped.empty?
  puts "スキップ記録が0件でした（本batchでは案2が発動しなかった、または計装なし）。"
else
  vals = skipped.map { |r| r[:input_mora] }.compact
  puts "n=#{vals.size}  mean=#{(vals.sum.to_f / vals.size).round(1)}  min=#{vals.min}  max=#{vals.max}"
  tally = vals.tally
  tally.keys.sort.each { |k| puts "  #{k}音: #{tally[k]}件" }

  total_flows = skipped.size + a1_count
  puts "\nスキップ率（全draft attempt中）= #{skipped.size}/#{total_flows} = " \
       "#{(100.0 * skipped.size / total_flows).round(1)}%"
end

puts "\n完了。"
