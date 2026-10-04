# frozen_string_literal: true
# 使い方: ruby script/analyze_dryrun.rb log/dryrun_hyakuin_20261004.log
# dryrun_hyakuin.rb のログ(1句1行)を集計する。Rails 不要。
LINE = /\A\[[^\]]+\]\s+(\d+)\s+\|\s+(.*?)\s+\|\s+(長|短)\s+\|\s+(\S+)\s+\|\s+(.*?)\s+\|\s+(OK|FORCED[^|]*?)\s*(?:\|\s*(.*))?\z/
WIND = /風|嵐|あらし|野分|颪|凩|こがらし/

verses = File.readlines(ARGV.fetch(0), chomp: true, encoding: "UTF-8").filter_map do |l|
  m = LINE.match(l) or next
  { no: m[1].to_i, text: m[2], kind: m[3], season: m[4], bui: m[5].split(","),
    status: m[6].start_with?("OK") ? :ok : :forced, reason: m[6], dup: m[7].to_s.include?("DUP") }
end

n = verses.size
forced = verses.select { |v| v[:status] == :forced }
puts "句数 #{n} / FORCED #{forced.size} (#{(forced.size * 100.0 / n).round(1)}%) / DUP #{verses.count { |v| v[:dup] }}"

cat = forced.group_by do |v|
  r = v[:reason]
  case r
  when /に合致しません/ then "音数"
  when /七句去物/ then "七句去物"
  when /部立「(.+?)」/ then "部立:#{$1}"
  when /季/ then "季"
  else "その他"
  end
end
puts "\n== FORCED の内訳 =="
cat.sort_by { |_, a| -a.size }.each { |k, a| puts format("%-12s %3d  %s", k, a.size, a.map { |v| v[:no] }.first(12).join(",")) }

puts "\n== 風体(LLM自己申告 vs 本文の風語) =="
lab = verses.select { |v| v[:bui].include?("風体") }
real = lab.select { |v| v[:text] =~ WIND }
puts "風体ラベル #{lab.size}句 / 本文に風語あり #{real.size}句 / 風語なしの誤ラベル #{(lab - real).size}句"
puts "  誤ラベル: " + (lab - real).map { |v| v[:no] }.join(",") unless (lab - real).empty?
only = verses.select { |v| v[:text] =~ WIND && !v[:bui].include?("風体") }
puts "  風語があるのにラベルなし: " + only.map { |v| v[:no] }.join(",") unless only.empty?
fv = forced.select { |v| v[:reason] =~ /部立「風体」/ }
puts "  風体が理由の FORCED: #{fv.size}句 (#{fv.map { |v| v[:no] }.join(',')})"

puts "\n== 季の分布(連続した同季の長さ) =="
runs = verses.slice_when { |a, b| a[:season] != b[:season] }.map { |g| [g.first[:season], g.size] }
runs.group_by(&:first).each { |s, a| puts format("%-2s 句数 %3d  連続 平均%.1f 最長%d", s, a.sum(&:last), a.sum(&:last).fdiv(a.size), a.map(&:last).max) }

puts "\n== 部立の頻度 =="
verses.flat_map { |v| v[:bui] }.tally.sort_by { |_, c| -c }.first(12).each { |b, c| puts format("%-8s %3d", b, c) }
