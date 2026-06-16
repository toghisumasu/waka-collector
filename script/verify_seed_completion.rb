# 実行: bin/rails runner script/verify_seed_completion.rb
# フェーズ8-3 版0ベース再構築 + 全改善統合
# 2026/06/15
#
# 統合内容:
#   [版0] 差分フィードバック（あと○音）復帰
#   [版1] EXAMPLESローテーション + echo潰し
#   [版2] 付合フィルタ（前句季節で核を絞る）
#   [新規] 多位置採取（二句・四句・結句）+ 末尾品詞フィルタ
#   [新規] wrong_streak（失敗全般で温度0.8に上昇）
#   [新規] 鸚鵡返しガード（核のよみと一致したら拒否）

require 'natto'
require 'benchmark'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

# 例文プール（attemptごとにローテーション：7音検算済み・現代ひらがな）
# こいしきものを: こ(1)い(1)し(1)き(1)も(1)の(1)を(1)=7
# ゆくはるのそら: ゆ(1)く(1)は(1)る(1)の(1)そ(1)ら(1)=7
# やまのあおぞら: や(1)ま(1)の(1)あ(1)お(1)ぞ(1)ら(1)=7
# つきのかたむく: つ(1)き(1)の(1)か(1)た(1)む(1)く(1)=7
# はるをよぶこえ: は(1)る(1)を(1)よ(1)ぶ(1)こ(1)え(1)=7
EXAMPLES = [
  { before: "あとをもみぬは", after: "こいしきものを" },
  { before: "かすみたなびく", after: "ゆくはるのそら" },
  { before: "しらくもかかる", after: "やまのあおぞら" },
  { before: "ながめておれば", after: "つきのかたむく" },
  { before: "うぐいすのねに", after: "はるをよぶこえ" },
].freeze
ECHO_AFTERS = EXAMPLES.map { |e| e[:after] }.freeze

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
FUKA_GETSU = %w[花 鳥 風 月 雪 霞 波 雲 雨 山 川 海 野 里 露 松 竹 草 水 煙 霧].freeze
SEASON_JP  = { spring: "春", summer: "夏", autumn: "秋", winter: "冬" }.freeze

# ---- モーラ計算 ----
# 注意: ひらがな以外が含まれると1文字=1モーラで誤計算するため
# has_kanji チェックと必ず併用すること
def mora_from_yomi(yomi)
  yomi.tr('ァ-ヴー', 'ぁ-ゔー').chars.reject { |c| YOUON.include?(c) }.size
end

def count_mora_from_kana(text)
  text.gsub(/[\s\u3000]/, '').chars.reject { |c| YOUON.include?(c) }.size
end

# ---- 形態素取得（feature付き: 末尾品詞フィルタで使用） ----
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

# ---- 指定位置のモーラ区間を抽出 ----
# skip_mora音をスキップし、take_mora音の断片を返す
# 形態素境界でモーラが割れる場合は nil を返す
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
      return {
        surface:    phrase.map { |x| x[:surface] }.join,
        yomi:       phrase.map { |x| x[:yomi].tr('ァ-ヴー', 'ぁ-ゔー') }.join,
        last_morph: phrase.last
      }
    end
    return nil if acc > take_mora
  end
  nil
end

# ---- 末尾品詞フィルタ ----
# ※ ipadic では終止形=「基本形」、連体形=「体言接続」と表記する
# 除外: 動詞(基本形)・助動詞(基本形)・助詞(終助詞)
#       動詞(体言接続)・助動詞(体言接続) ← 句末での連体止め
# 例: よなよななかむ（む=助動詞・基本形）
#     をりてけるかな（かな=助詞・終助詞）
#     たのまさりける（ける=助動詞・体言接続）← 今回追加
#     うらみはてたる（たる=助動詞・体言接続）← 今回追加
def open_phrase?(last_morph)
  f       = last_morph[:feature].split(',')
  pos     = f[0]
  pos_sub = f[1]
  katsuyo = f[5]
  return false if pos == '動詞'   && katsuyo == '基本形'
  return false if pos == '助動詞' && katsuyo == '基本形'
  return false if pos == '助詞'   && pos_sub == '終助詞'
  return false if pos == '動詞'   && katsuyo == '体言接続'
  return false if pos == '助動詞' && katsuyo == '体言接続'
  true
end

# ---- 季節タグ（プール構築時に計算、seedに格納） ----
def compute_season_tag(waka_upper, waka_lower)
  full = waka_upper.to_s + waka_lower.to_s
  key  = SEASON_WORDS.find { |_, words| words.any? { |w| full.include?(w) } }&.first
  key ? SEASON_JP[key] : nil
end

# ---- ヒントシステム（出典和歌から情景語を抽出） ----
# 季節はseed[:season]から取得（プール構築時に計算済み）
def extract_hints(seed)
  full   = seed[:waka_upper] + seed[:waka_lower]
  nature = FUKA_GETSU.select { |w| full.include?(w) }
  parts  = []
  parts << "季節：#{seed[:season]}" if seed[:season]
  parts << "情景：#{nature.uniq.join('・')}" if nature.any?
  parts.empty? ? nil : parts.join(" / ")
end

# ---- 前句の季節・情景 ----
def maeku_season(maeku)
  SEASON_WORDS.find { |_, words| words.any? { |w| maeku.include?(w) } }&.first
end

def maeku_nature(maeku)
  FUKA_GETSU.select { |w| maeku.include?(w) }
end

# ---- MeCab初期化 ----
nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  puts "ユーザー辞書なし（#{e.message}）→標準辞書で起動"
  Natto::MeCab.new
end

# ---- 核プール構築（三位置採取 + 末尾品詞フィルタ） ----
puts "前7音核プールを構築中（三位置採取 + 主部フィルタ）..."
seeds = []

Waka.where.not(upper_phrase_text: [nil, ''])
    .where.not(lower_phrase_text:  [nil, '']).each do |w|

  upper_ms = morphemes_of(w.upper_phrase_text.strip, nm)
  lower_ms = morphemes_of(w.lower_phrase_text.strip, nm)
  stag     = compute_season_tag(w.upper_phrase_text, w.lower_phrase_text)
  base     = { waka_upper: w.upper_phrase_text.to_s,
               waka_lower: w.lower_phrase_text.to_s,
               season:     stag }

  upper_total = upper_ms.sum { |m| m[:mora] }
  lower_total = lower_ms.sum { |m| m[:mora] }

  # 二句（上句後7音: 初句5音をスキップ）
  if upper_total == 17
    seg = extract_mora_segment(upper_ms, 5, 7)
    seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi],
                        position: "二句") if seg && open_phrase?(seg[:last_morph])
  end

  if lower_total == 14
    # 四句（下句前7音: 従来の核プール相当）
    seg = extract_mora_segment(lower_ms, 0, 7)
    seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi],
                        position: "四句") if seg && open_phrase?(seg[:last_morph])

    # 結句（下句後7音: 四句7音をスキップ）
    seg = extract_mora_segment(lower_ms, 7, 7)
    seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi],
                        position: "結句") if seg && open_phrase?(seg[:last_morph])
  end
end

puts "核プール: #{seeds.size}件\n\n"

# ---- 検証：ランダムに5件試す ----
maeku    = "ちはやぶる神代も聞かず竜田川"
m_season = maeku_season(maeku)
m_nature = maeku_nature(maeku)

# 付合フィルタ: 前句の季節に一致する核を優先
pool = if m_season
  candidate = seeds.select { |s| s[:season] == SEASON_JP[m_season] }
  if candidate.any?
    puts "付合フィルタ：#{SEASON_JP[m_season]}の核 #{candidate.size}件 / 全#{seeds.size}件"
    candidate
  else
    puts "付合フィルタ：#{SEASON_JP[m_season]}の核が見つからず全体にフォールバック"
    seeds
  end
else
  puts "付合フィルタ：前句に季語なし（全体からサンプル）"
  seeds
end
puts ""

used_afters = []  # dynamic blacklist
all_attempts = []  # 音数NG含む全候補ブラックリスト
5.times do |i|
  seed       = pool.sample
  hints      = extract_hints(seed)
  maeku_hint = m_nature.any? ? "前句の情景：#{m_nature.join('・')}" : nil

  puts "=== 試行#{i + 1} ==="
  puts "核（前7音）：#{seed[:surface]}（よみ：#{seed[:yomi]}）[#{seed[:position]}]"
  puts "元の和歌：#{seed[:waka_upper]}#{seed[:waka_lower]}"
  puts "核のヒント：#{hints || 'なし'}"

  feedback     = nil
  result_ku    = nil
  wrong_streak = 0   # 失敗全般のカウント（漢字・echo・音数・鸚鵡返しいずれも）

  5.times do |attempt|
    example     = EXAMPLES[attempt % EXAMPLES.size]
    # wrong_streak が2回以上で温度を上げて多様性を確保
    temperature = wrong_streak >= 2 ? 0.8 : 0.5

    hint_parts = [maeku_hint, hints ? "元の和歌より：#{hints}" : nil].compact
    hint_line  = hint_parts.any? ? "【付合の手がかり】#{hint_parts.join(' / ')}\n" : ""

    prompt = <<~PROMPT
      あなたは連歌の執筆役です。

      【前句】
      #{maeku}

      #{hint_line}【指示】
      短句（七七）の前半はすでに決まっています。
      後半の7音のみをひらがなで出力してください。
      前半の言葉は出力しないこと。
      前半を「主部・条件・理由」、後半をそれを受ける「述部」として完成させてください。
      例：「#{example[:before]}」→「#{example[:after]}」

      前半（決定済み）：#{seed[:surface]}

      #{feedback ? "【やり直し】前回「#{feedback[:ku]}」は#{feedback[:issue]}。#{feedback[:message]}" : ""}

      【出力ルール】
      - ひらがなのみで7音ちょうどを1行で出力する。
      - 前半の言葉を繰り返さない。
      - 例文の言葉（「#{example[:after]}」）をそのままコピーしない。
      - 説明・記号・句読点は一切出力しない。

      後半の7音：
    PROMPT

    result  = nil
    elapsed = Benchmark.realtime do
      result = OllamaClient.generate(prompt, timeout: 120, think: false, temperature: temperature)
    end

    ku            = result.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
    mora          = count_mora_from_kana(ku)
    has_kanji     = ku.match?(/[^\u3040-\u309F\u3099-\u309C\s]/)
    is_echo       = ECHO_AFTERS.include?(ku)
    is_repetition = (ku == seed[:yomi])
    all_attempts << ku
    is_sticky     = used_afters.count(ku) >= 2 || all_attempts.count(ku) >= 3

    temp_label = temperature == 0.8 ? "🌡" : ""
    flags = [
      (has_kanji     ? "漢字混入" : nil),
      (is_echo       ? "echo"     : nil),
      (is_repetition ? "鸚鵡返し"  : nil),
      (is_sticky     ? "固着"      : nil)
    ].compact.join("・")
    flag_str = flags.empty? ? "" : "・#{flags}"

    puts "  attempt#{attempt + 1}#{temp_label}[例:#{example[:after]}]: #{ku}（#{mora}音#{flag_str}）#{elapsed.round(1)}秒"

    if mora == 7 && !has_kanji && !is_echo && !is_repetition && !is_sticky
      result_ku = ku
      used_afters << ku
      break
    end

    wrong_streak += 1

    if wrong_streak >= 3
      seed         = pool.sample
      hints        = extract_hints(seed)
      wrong_streak = 0
      feedback     = nil
      puts "  [seed swap] #{seed[:surface]} [#{seed[:position]}]"
    end

    # 版0の差分フィードバック復帰
    # 音数は「あと○音」の差分指示（収束実績あり）
    # それ以外は理由を明示して意識を向け直す
    issue, msg = if is_repetition
      ["前半と同じ言葉", "前半とは別の言葉で後半を詠んでください。"]
    elsif is_echo
      ["例文と同じ言葉", "例文の言葉をそのままコピーしないでください。別の表現で詠んでください。"]
    elsif has_kanji
      ["漢字が含まれている", "ひらがなのみで出力してください（漢字・カタカナ禁止）。"]
    elsif mora < 7
      ["#{mora}音", "あと#{7 - mora}音増やして7音にしてください。"]
    else
      ["#{mora}音", "#{mora - 7}音減らして7音にしてください。"]
    end
    feedback = { ku: ku, issue: issue, message: msg }
  end

  if result_ku
    puts "合成した付け句：#{seed[:surface]}#{result_ku}"
    puts "→ OK!"
  else
    puts "→ 5回試行後も7音が得られず"
  end
  puts ""
end

