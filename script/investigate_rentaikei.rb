# 実行: bin/rails runner script/investigate_rentaikei.rb
# 問題A調査: 連体形で終わる核の実態を洗い出す
# 目的: 「連体形止め」を一律除外すべきか、品詞の組み合わせで選別すべきかを判断する
# LLM呼び出しなし（MeCab + DB のみ）
require 'natto'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

def mora_from_yomi(yomi)
  yomi.tr('ァ-ヴー', 'ぁ-ゔー').chars.reject { |c| YOUON.include?(c) }.size
end

def morphemes_of(text, nm)
  result = []
  nm.parse(text.gsub(/[\s\u3000]+/, '')) do |node|
    next if node.is_eos?
    f    = node.feature.split(',')
    yomi = f[7] || node.surface
    result << {
      surface: node.surface,
      yomi:    yomi,
      mora:    mora_from_yomi(yomi),
      feature: node.feature
    }
  end
  result
end

def extract_mora_segment(morphemes, skip_mora, take_mora)
  start_idx = 0
  if skip_mora > 0
    acc   = 0
    found = false
    morphemes.each_with_index do |m, i|
      acc += m[:mora]
      if acc == skip_mora
        start_idx = i + 1
        found = true
        break
      end
      return nil if acc > skip_mora
    end
    return nil unless found
  end
  remaining = morphemes[start_idx..]
  return nil if remaining.nil? || remaining.empty?
  acc = 0
  remaining.each_with_index do |m, i|
    acc += m[:mora]
    if acc == take_mora
      phrase = remaining[0..i]
      return { surface: phrase.map { |x| x[:surface] }.join, phrase: phrase }
    end
    return nil if acc > take_mora
  end
  nil
end

# 現行フィルタ（基本形・終助詞のみ除外）
def open_phrase?(last_morph)
  f       = last_morph[:feature].split(',')
  pos     = f[0]
  pos_sub = f[1]
  katsuyo = f[5]
  return false if pos == '動詞'   && katsuyo == '基本形'
  return false if pos == '助動詞' && katsuyo == '基本形'
  return false if pos == '助詞'   && pos_sub == '終助詞'
  true
end

# 末尾形態素が連体形か
def rentaikei?(last_morph)
  f = last_morph[:feature].split(',')
  f[5].to_s.include?('連体形')
end

nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue
  Natto::MeCab.new
end

# 連体形で終わる核を、末尾の品詞別に分類して収集
# キー: "品詞/活用型" 例: "動詞/五段・ラ行" "助動詞/特殊・ケリ"
rentai = Hash.new { |h, k| h[k] = [] }
rentai_total = 0
open_total   = 0

collect = lambda do |seg, position, waka|
  return unless seg
  last = seg[:phrase].last
  open_total += 1 if open_phrase?(last)
  return unless open_phrase?(last)      # 現行フィルタを通過したものだけ調査
  return unless rentaikei?(last)        # そのうち連体形で終わるもの
  rentai_total += 1
  f   = last[:feature].split(',')
  key = "#{f[0]}/#{f[4]}"               # 品詞/活用型
  if rentai[key].size < 6               # キーごとに最大6サンプル
    # 末尾2形態素を表示（連体形の「下に続くはずの語」が無いことを見るため）
    tail = seg[:phrase].last(2).map { |m| m[:surface] }.join("│")
    rentai[key] << { surface: seg[:surface], tail: tail, waka: waka }
  end
end

Waka.where.not(upper_phrase_text: [nil, ''])
    .where.not(lower_phrase_text:  [nil, '']).each do |w|
  upper_ms = morphemes_of(w.upper_phrase_text.strip, nm)
  lower_ms = morphemes_of(w.lower_phrase_text.strip, nm)
  waka = "#{w.upper_phrase_text}#{w.lower_phrase_text}"

  collect.call(extract_mora_segment(upper_ms, 5, 7), "二句", waka) if upper_ms.sum { |m| m[:mora] } == 17
  if lower_ms.sum { |m| m[:mora] } == 14
    collect.call(extract_mora_segment(lower_ms, 0, 7), "四句", waka)
    collect.call(extract_mora_segment(lower_ms, 7, 7), "結句", waka)
  end
end

puts "=== 連体形で終わる核の調査 ==="
puts "現行フィルタ通過核（全体）: #{open_total}件"
puts "うち連体形で終わる核     : #{rentai_total}件（#{(rentai_total.to_f / open_total * 100).round(1)}%）"
puts ""
puts "末尾の品詞・活用型ごとの内訳と、判定の手がかり（末尾2形態素を│で区切って表示）"
puts "=" * 70

# 件数の多い順に表示
counts = Hash.new(0)
Waka.where.not(upper_phrase_text: [nil, ''])
    .where.not(lower_phrase_text:  [nil, '']).each do |w|
  upper_ms = morphemes_of(w.upper_phrase_text.strip, nm)
  lower_ms = morphemes_of(w.lower_phrase_text.strip, nm)
  check = lambda do |seg|
    return unless seg
    last = seg[:phrase].last
    return unless open_phrase?(last) && rentaikei?(last)
    f = last[:feature].split(',')
    counts["#{f[0]}/#{f[4]}"] += 1
  end
  check.call(extract_mora_segment(upper_ms, 5, 7)) if upper_ms.sum { |m| m[:mora] } == 17
  if lower_ms.sum { |m| m[:mora] } == 14
    check.call(extract_mora_segment(lower_ms, 0, 7))
    check.call(extract_mora_segment(lower_ms, 7, 7))
  end
end

rentai.keys.sort_by { |k| -counts[k] }.each do |key|
  puts "\n【#{key}】 #{counts[key]}件"
  rentai[key].each do |s|
    puts "  #{s[:surface]}  （末尾: #{s[:tail]}）"
  end
end

