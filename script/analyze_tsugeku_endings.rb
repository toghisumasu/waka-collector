# 実行: bin/rails runner script/analyze_tsugeku_endings.rb
require 'natto'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

# 語尾が不自然とみなす末尾パターン（最後の形態素の表層）
SUSPICIOUS_ENDINGS = %w[
  に で を は も が と や から まで より
  ぬ ず つつ て けり てき にき
].freeze

def mora_from_yomi(yomi)
  yomi.tr('ァ-ヴー', 'ぁ-ゔー').chars.reject { |c| YOUON.include?(c) }.size
end

def morphemes_of(text, nm)
  result = []
  nm.parse(text.gsub(/[\s　]+/, '')) do |node|
    next if node.is_eos?
    f    = node.feature.split(',')
    yomi = f[7] || node.surface
    result << { surface: node.surface, yomi: yomi.tr('ァ-ヴー', 'ぁ-ゔー'), mora: mora_from_yomi(yomi) }
  end
  result
end

nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  puts "ユーザー辞書なし (#{e.message})、標準辞書で続行"
  Natto::MeCab.new
end

rows = Renga.where.not(tsugeku: [nil, '']).order(:id)
puts "対象: #{rows.size} 件\n\n"

pattern_counts  = Hash.new(0)  # パターン文字列 → 件数
pattern_examples = Hash.new { |h, k| h[k] = [] }  # パターン → 句例

rows.each do |renga|
  ku = renga.tsugeku.strip
  ms = morphemes_of(ku, nm)
  next if ms.empty?

  # 末尾3〜4形態素の表層を語尾パターンとして採用
  tail4 = ms.last([ms.size, 4].min).map { |m| m[:surface] }.join
  tail3 = ms.last([ms.size, 3].min).map { |m| m[:surface] }.join

  # 音数が多い方（4形態素）を優先し、2文字以下になる場合は3形態素
  pattern = tail4.length >= 3 ? tail4 : tail3

  pattern_counts[pattern] += 1
  pattern_examples[pattern] << ku if pattern_examples[pattern].size < 2
end

# 末尾形態素の表層だけも別途集計（1形態素単位での注意チェック用）
last_morph_counts = Hash.new(0)
rows.each do |renga|
  ku = renga.tsugeku.strip
  ms = morphemes_of(ku, nm)
  next if ms.empty?
  last_morph_counts[ms.last[:surface]] += 1
end

# ---- 出力 ----
puts "=" * 60
puts "【語尾パターン（末尾3〜4形態素）頻度ランキング】"
puts "=" * 60

sorted = pattern_counts.sort_by { |_, v| -v }
sorted.each do |pattern, count|
  last_surface = pattern.chars.last(4).join  # 末尾数文字で判定
  suspicious   = SUSPICIOUS_ENDINGS.any? { |e| pattern.end_with?(e) }
  flag         = suspicious ? " ← 注意" : ""
  examples     = pattern_examples[pattern].map { |k| "「#{k}」" }.join(", ")
  puts "  #{pattern}: #{count}件#{flag}   例) #{examples}"
end

puts "\n"
puts "=" * 60
puts "【末尾1形態素ランキング（注意マーク付き）】"
puts "=" * 60

last_morph_counts.sort_by { |_, v| -v }.each do |surface, count|
  suspicious = SUSPICIOUS_ENDINGS.include?(surface)
  flag       = suspicious ? " ← 注意" : ""
  puts "  #{surface}: #{count}件#{flag}"
end

puts "\n"
puts "=" * 60
puts "【注意パターン一覧（句例付き）】"
puts "=" * 60

suspicious_only = sorted.select { |pattern, _| SUSPICIOUS_ENDINGS.any? { |e| pattern.end_with?(e) } }
if suspicious_only.empty?
  puts "  注意パターンなし"
else
  suspicious_only.each do |pattern, count|
    puts "  #{pattern}: #{count}件"
    pattern_examples[pattern].each { |k| puts "      → #{k}" }
  end
end
