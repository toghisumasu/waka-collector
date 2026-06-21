# 実行: bin/rails runner script/extract_7mora_seeds.rb
require 'natto'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

def mora_from_yomi(yomi)
  hiragana = yomi.tr('ァ-ヴー', 'ぁ-ゔー')
  hiragana.chars.reject { |c| YOUON.include?(c) }.size
end

# 形態素リストを返す
def morphemes_of(text, nm)
  result = []
  nm.parse(text.gsub(/\s+/, '')) do |node|
    next if node.is_eos?
    features = node.feature.split(',')
    yomi = features[7] || node.surface
    result << { surface: node.surface, yomi: yomi, mora: mora_from_yomi(yomi) }
  end
  result
end

# 形態素境界でちょうど7モーラになる分割点を探す
def split_7_7(morphemes)
  acc = 0
  morphemes.each_with_index do |m, i|
    acc += m[:mora]
    if acc == 7
      first  = morphemes[0..i]
      second = morphemes[(i + 1)..]
      return {
        first_surface:  first.map  { |x| x[:surface] }.join,
        first_yomi:     first.map  { |x| x[:yomi].tr('ァ-ヴー','ぁ-ゔー') }.join,
        second_surface: second.map { |x| x[:surface] }.join,
        second_mora:    second.sum { |x| x[:mora] }
      }
    end
    return nil if acc > 7  # 超えたら分割不可
  end
  nil
end

# MeCab初期化（ユーザー辞書がなければ標準辞書で起動）
nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  puts "ユーザー辞書なし（#{e.message}）→標準辞書で起動"
  Natto::MeCab.new
end

total = clean = wrong_mora = overshot = 0
seeds = []

puts "=== 下の句 7+7 分割テスト（最初の500首） ==="

Waka.where.not(lower_phrase_text: [nil, '']).limit(500).each do |w|
  text = w.lower_phrase_text.strip
  next if text.empty?
  total += 1

  ms        = morphemes_of(text, nm)
  total_mora = ms.sum { |m| m[:mora] }

  if total_mora != 14
    wrong_mora += 1
    next
  end

  result = split_7_7(ms)
  if result && result[:second_mora] == 7
    clean += 1
    seeds << { original: text, **result } if seeds.size < 20
  else
    overshot += 1
  end
end

valid = total - wrong_mora
puts "対象: #{total}首"
puts "  14音でない（MeCab判定）: #{wrong_mora}首"
puts "  7+7クリーン分割: #{clean}首 / #{valid}首 (#{valid > 0 ? (clean.to_f/valid*100).round(1) : 0}%)"
puts "  形態素をまたぐ（分割不可）: #{overshot}首"
puts ""
puts "=== サンプル（最大20件） ==="
seeds.each do |s|
  puts "元: #{s[:original]}"
  puts "  前7音: #{s[:first_surface]}（よみ: #{s[:first_yomi]}）"
  puts "  後7音: #{s[:second_surface]}"
  puts ""
end
