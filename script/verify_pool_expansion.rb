# 実行: bin/rails runner script/verify_pool_expansion.rb
# 核プール拡張テスト: 多位置採取 + 末尾品詞フィルタ
# 採取位置: 二句(上句後7音) / 四句(下句前7音) / 結句(下句後7音)
# LLM呼び出しなし: MeCab + DB のみ（数秒で完了）
require 'natto'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

# 「花」はspringから除外（FUKA_GETSUに残す）
# 「もみち」追加（歴史的仮名遣いの表記ゆれ対応）
SEASON_WORDS = {
  spring: %w[春 霞 梅 桜 鶯 柳 蛙 燕 桃 朧 若草 菜の花 山吹 かすみ うぐいす
             わらび ふきのとう すみれ たんぽぽ よもぎ],
  summer: %w[夏 郭公 ほととぎす 蛍 五月雨 蓮 卯の花 青葉 緑 時鳥 さみだれ
             あやめ しょうぶ],
  autumn: %w[秋 月 紅葉 もみじ もみち 露 雁 鹿 萩 菊 竜田 嵐 時雨 霧 しぐれ きり
             おみなえし ききょう],
  winter: %w[冬 雪 霜 氷 枯 千鳥 鷺 さむ みぞれ しも かれの]
}.freeze
SEASON_JP = { spring: "春", summer: "夏", autumn: "秋", winter: "冬" }.freeze

# ---- モーラ計算 ----
def mora_from_yomi(yomi)
  yomi.tr('ァ-ヴー', 'ぁ-ゔー').chars.reject { |c| YOUON.include?(c) }.size
end

# ---- 形態素取得（feature付き） ----
# feature を保持することで末尾品詞フィルタが使えるようになる
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
      feature: node.feature   # 末尾品詞フィルタ用
    }
  end
  result
end

# ---- 指定位置のモーラ区間を抽出 ----
# skip_mora音をスキップし、take_mora音の断片を返す
# 形態素境界でモーラが割れる場合（e.g.二重母音の途中）は nil を返す
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
      return nil if acc > skip_mora  # 形態素がモーラ境界を越えた
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
      return {
        surface:    phrase.map { |x| x[:surface] }.join,
        yomi:       phrase.map { |x| x[:yomi].tr('ァ-ヴー', 'ぁ-ゔー') }.join,
        last_morph: phrase.last
      }
    end
    return nil if acc > take_mora   # オーバーシュート
  end
  nil
end

# ---- 末尾品詞フィルタ ----
# MeCab ipadic の feature 配列:
#   [0]品詞 [1]品詞細分類1 [4]活用型 [5]活用形 [6]原形 [7]読み
# ※ ipadic では終止形=「基本形」、連体形=「体言接続」と表記する
# 除外対象:
#   動詞(基本形)   : みる・する・つくる 等 → 述部終止
#   助動詞(基本形) : けり・なり・む 等     → 述部終止
#   助詞(終助詞)   : かな・ぞ・な・よ 等   → 文末
#   動詞(体言接続) : 句末で体言が続かない連体止め → 述部連体止め
#   助動詞(体言接続): たる・ける・める 等   → 述部連体止め
# 通過: 助詞(係助詞・格助詞・連体化)、名詞、動詞(連用形) 等
def open_phrase?(last_morph)
  f       = last_morph[:feature].split(',')
  pos     = f[0]   # 品詞
  pos_sub = f[1]   # 品詞細分類1
  katsuyo = f[5]   # 活用形
  return false if pos == '動詞'   && katsuyo == '基本形'
  return false if pos == '助動詞' && katsuyo == '基本形'
  return false if pos == '助詞'   && pos_sub == '終助詞'
  return false if pos == '動詞'   && katsuyo == '体言接続'
  return false if pos == '助動詞' && katsuyo == '体言接続'
  true
end

# フィルタ判定根拠をログ用に整形
def pos_label(last_morph)
  f = last_morph[:feature].split(',')
  "#{f[0]}(#{f[1]}) #{f[5]}"
end

# ---- 季節タグ ----
def season_tag(waka_upper, waka_lower)
  full = waka_upper.to_s + waka_lower.to_s
  key  = SEASON_WORDS.find { |_, words| words.any? { |w| full.include?(w) } }&.first
  key ? SEASON_JP[key] : nil
end

# ---- MeCab初期化 ----
nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  puts "ユーザー辞書なし（#{e.message}）→標準辞書で起動"
  Natto::MeCab.new
end

# ---- 集計用構造 ----
stats = {
  niku:  { raw: 0, open: 0, season: Hash.new(0) },  # 二句
  yonku: { raw: 0, open: 0, season: Hash.new(0) },  # 四句
  kekku: { raw: 0, open: 0, season: Hash.new(0) }   # 結句
}

accepted_samples = []  # 通過サンプル（最大30件）
rejected_samples = []  # 除外サンプル（最大15件）

puts "スキャン中..."

Waka.where.not(upper_phrase_text: [nil, ''])
    .where.not(lower_phrase_text:  [nil, '']).each do |w|

  upper_ms = morphemes_of(w.upper_phrase_text.strip, nm)
  lower_ms = morphemes_of(w.lower_phrase_text.strip, nm)
  stag     = season_tag(w.upper_phrase_text, w.lower_phrase_text)

  upper_total = upper_ms.sum { |m| m[:mora] }
  lower_total = lower_ms.sum { |m| m[:mora] }

  # --- 二句: 上句の後7音（初句5音をスキップ） ---
  if upper_total == 17
    seg = extract_mora_segment(upper_ms, 5, 7)
    if seg
      stats[:niku][:raw] += 1
      if open_phrase?(seg[:last_morph])
        stats[:niku][:open] += 1
        stats[:niku][:season][stag] += 1 if stag
        if accepted_samples.size < 30
          accepted_samples << { pos: "二句", surface: seg[:surface],
                                season: stag, label: pos_label(seg[:last_morph]) }
        end
      else
        if rejected_samples.size < 15
          rejected_samples << { pos: "二句", surface: seg[:surface],
                                label: pos_label(seg[:last_morph]) }
        end
      end
    end
  end

  # --- 四句: 下句の前7音（従来の核プール） ---
  if lower_total == 14
    seg = extract_mora_segment(lower_ms, 0, 7)
    if seg
      stats[:yonku][:raw] += 1
      if open_phrase?(seg[:last_morph])
        stats[:yonku][:open] += 1
        stats[:yonku][:season][stag] += 1 if stag
        if accepted_samples.size < 30
          accepted_samples << { pos: "四句", surface: seg[:surface],
                                season: stag, label: pos_label(seg[:last_morph]) }
        end
      else
        if rejected_samples.size < 15
          rejected_samples << { pos: "四句", surface: seg[:surface],
                                label: pos_label(seg[:last_morph]) }
        end
      end
    end

    # --- 結句: 下句の後7音（四句7音をスキップ） ---
    seg = extract_mora_segment(lower_ms, 7, 7)
    if seg
      stats[:kekku][:raw] += 1
      if open_phrase?(seg[:last_morph])
        stats[:kekku][:open] += 1
        stats[:kekku][:season][stag] += 1 if stag
        if accepted_samples.size < 30
          accepted_samples << { pos: "結句", surface: seg[:surface],
                                season: stag, label: pos_label(seg[:last_morph]) }
        end
      else
        if rejected_samples.size < 15
          rejected_samples << { pos: "結句", surface: seg[:surface],
                                label: pos_label(seg[:last_morph]) }
        end
      end
    end
  end
end

# ---- 集計表 ----
puts "\n=== 核プール拡張テスト結果 ===\n\n"

total_raw  = stats.values.sum { |s| s[:raw] }
total_open = stats.values.sum { |s| s[:open] }
total_season = Hash.new(0)
stats.each_value { |s| s[:season].each { |k, v| total_season[k] += v } }

puts "%-10s %8s %12s %10s %10s" % ["位置", "採取数", "主部フィルタ後", "通過率", "季タグ付き"]
puts "-" * 58
[
  ["二句(7音)", stats[:niku]],
  ["四句(7音)", stats[:yonku]],
  ["結句(7音)", stats[:kekku]]
].each do |label, s|
  rate = s[:raw] > 0 ? (s[:open].to_f / s[:raw] * 100).round(1) : 0
  puts "%-10s %8d %12d %9.1f%% %10d" % [label, s[:raw], s[:open], rate, s[:season].values.sum]
end
puts "-" * 58
rate = total_raw > 0 ? (total_open.to_f / total_raw * 100).round(1) : 0
puts "%-10s %8d %12d %9.1f%% %10d" % ["合計", total_raw, total_open, rate, total_season.values.sum]
puts "\n参考: 従来の四句のみ・フィルタなし = #{stats[:yonku][:raw]}件"

puts "\n--- 季節別内訳（主部フィルタ後・全位置合計）---"
total_season.sort_by { |_, v| -v }.each do |season, count|
  puts "  #{season}: #{count}件"
end

puts "\n--- 主部フィルタ通過サンプル（最大30件）---"
accepted_samples.each do |s|
  sstr = s[:season] ? "（#{s[:season]}）" : "（無季）"
  puts "  [#{s[:pos]}] #{s[:surface]} #{sstr} ← #{s[:label]}"
end

puts "\n--- 主部フィルタ除外サンプル（最大15件）---"
rejected_samples.each do |s|
  puts "  [#{s[:pos]}] #{s[:surface]} ← 除外: #{s[:label]}"
end

