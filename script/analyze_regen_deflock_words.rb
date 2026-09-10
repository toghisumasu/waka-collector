# frozen_string_literal: true

# analyze_regen_deflock_words.rb — 依頼書 D-XX-2：再生成プロンプト強化実験の効果判定
#
# renga_internal_*.jsonl（RengaGenerator#log_internal_attempt が書く内部試行ログ）を読み、
# デフロック語の出現率を「初回生成（internal_attempt == 1）」と
# 「再生成（internal_attempt >= 2）」で比較する。
#
#   internal_attempt == 1  … generate_tsugeku の各verse最初の試行 = feedback nil = 初回プロンプト
#   internal_attempt >= 2  … 2回目以降 = feedback 非nil = 再生成プロンプト（今回の一文が入る分岐）
#
# 使用法:
#   bundle exec ruby script/analyze_regen_deflock_words.rb log/renga_internal_<batch>_<date>_<date>.jsonl
#   bundle exec ruby script/analyze_regen_deflock_words.rb log/renga_internal_*.jsonl   # 複数可

require "json"

# 依頼書 §観測項目のデフロック語。表記ゆれ（送り仮名・活用）も拾う。
DEFLOCK_WORDS = {
  "揺れる" => /揺れ|ゆれ/,
  "光"     => /光|ひかり/,
  "重さ"   => /重[さみい]|おも[さみい]/,
  "肌"     => /肌|はだ/,
  "香る"   => /香[るり]|かお[るり]|薫[るり]/,
  "月"     => /月|つき/,
  "霞"     => /霞|かすみ/,
  "心"     => /心|こころ/
}.freeze

paths = ARGV
abort "使用法: bundle exec ruby script/analyze_regen_deflock_words.rb <renga_internal_*.jsonl> [...]" if paths.empty?

rows = []
paths.each do |path|
  abort "ファイルが見つかりません: #{path}" unless File.exist?(path)
  File.foreach(path) do |line|
    line = line.strip
    next if line.empty?

    begin
      rows << JSON.parse(line)
    rescue JSON::ParserError
      warn "パース失敗（スキップ）: #{line[0, 80]}"
    end
  end
end

abort "有効な行がありません" if rows.empty?

def bucket_stats(rows, label)
  total = rows.size
  puts "\n## #{label}（試行 #{total} 件）"
  return if total.zero?

  any_hit = 0
  rows.each do |r|
    text = r["first_line_result"].to_s
    any_hit += 1 if DEFLOCK_WORDS.any? { |_, re| text.match?(re) }
  end

  puts format("  デフロック語をいずれか含む: %d / %d = %.1f%%", any_hit, total, 100.0 * any_hit / total)
  puts "  語別出現率:"
  DEFLOCK_WORDS.each do |word, re|
    hit = rows.count { |r| r["first_line_result"].to_s.match?(re) }
    puts format("    %-6s %4d / %-4d = %5.1f%%", word, hit, total, 100.0 * hit / total)
  end
end

initial = rows.select { |r| r["internal_attempt"].to_i == 1 }
regen   = rows.select { |r| r["internal_attempt"].to_i >= 2 }

puts "=" * 60
puts "再生成プロンプト強化実験（D-XX-2）デフロック語出現率"
puts "対象ファイル: #{paths.join(', ')}"
puts "総試行数: #{rows.size}　verse数: #{rows.map { |r| r['verse_no'] }.compact.uniq.size}"
puts "=" * 60

bucket_stats(initial, "初回生成 internal_attempt == 1")
bucket_stats(regen,   "再生成   internal_attempt >= 2（今回の一文が入る分岐）")

puts "\n" + "=" * 60
puts "判定の目安: 再生成のデフロック語率が初回より有意に低ければ一文の効果あり。"
puts "（socratic経路 rejection_reason 由来の試行も internal_attempt>=2 に混ざる点に留意）"
