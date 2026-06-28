# frozen_string_literal: true
require "natto"
require "yaml"

class RengaGenerator
  USER_DIC = Rails.root.join("dict", "user.dic").to_s

  YOUON = %w[ゃ ゅ ょ].freeze

  EXAMPLES = [
    { before: "あとをもみぬは",   after: "こいしきものを" },
    { before: "かすみたなびく",   after: "ゆくはるのそら" },
    { before: "しらくもかかる",   after: "やまのあおぞら" },
    { before: "ながめておれば",   after: "つきのかたむく" },
    { before: "うぐいすのねに",   after: "はるをよぶこえ" },
  ].freeze

  ECHO_AFTERS = EXAMPLES.map { |e| e[:after] }.freeze

  DECORATION_POOL = YAML.load_file(
    Rails.root.join("app/data/decoration_pool.yml")
  ).freeze

  MAKURA_MAP = YAML.load_file(
    Rails.root.join("app/data/makura_map.yml")
  ).freeze

  SEASON_WORDS = {
    spring: %w[春 霞 梅 桜 鶯 柳 蛙 燕 桃 朧 若草 菜の花 山吹 かすみ うぐいす わらび ふきのとう すみれ たんぽぽ よもぎ],
    summer: %w[夏 郭公 ほととぎす 蛍 五月雨 蓮 卯の花 青葉 緑 時鳥 さみだれ あやめ しょうぶ],
    autumn: %w[秋 月 紅葉 もみじ もみち 露 雁 鹿 萩 菊 竜田 嵐 時雨 霧 しぐれ きり おみなえし ききょう],
    winter: %w[冬 雪 霜 氷 枯 千鳥 鷺 さむ みぞれ しも かれの]
  }.freeze

  FUKA_GETSU = %w[花 鳥 風 月 雪 霞 波 雲 雨 山 川 海 野 里 露 松 竹 草 水 煙 霧].freeze
  SEASON_JP  = { spring: "春", summer: "夏", autumn: "秋", winter: "冬" }.freeze

  KIGO_BUI = {
    "霞" => "聳物", "かすみ" => "聳物", "霧" => "聳物", "きり" => "聳物",
    "月" => "光物", "朧" => "光物",
    "梅" => "花", "桜" => "花", "菜の花" => "花", "山吹" => "花", "菊" => "花",
    "柳" => "木", "騨" => "木", "もみじ" => "木", "もみち" => "木",
    "若草" => "草", "わらび" => "草", "よもぎ" => "草",
    "萩" => "草", "おみなえし" => "草", "ききょう" => "草", "かれの" => "草",
    "蛍" => "虫", "蝶" => "虫", "蛙" => "虫",
    "郭公" => "鳥", "ほととぎす" => "鳥", "鶯" => "鳥", "うぐいす" => "鳥",
    "雁" => "鳥", "千鳥" => "鳥", "鷺" => "鳥",
    "鹿" => "獣",
    "露" => "降物", "五月雨" => "降物", "時雨" => "降物", "しぐれ" => "降物",
    "雪" => "降物", "霜" => "降物", "しも" => "降物", "みぞれ" => "降物",
  }.freeze

  BUI_EXAMPLE_WORDS = {
    "降物" => "雨・雪・露・霜・時雨・霰",
    "聳物" => "霞・霧・雲・煙",
    "光物" => "月・日・星",
    "花" => "梅・桜・菊・山吹",
    "草" => "萩・薄・若草",
    "木" => "柳・松・冬木立",
    "植物" => "草木・花全般",
    "鳥" => "鶯・雁・鴨・千鳥",
    "虫" => "蛍・蟋蟀・蝶",
    "獣" => "鹿・狐",
    "動物" => "鳥・虫・獣全般",
    "水辺" => "川・海・池・渚",
    "山類" => "山・峰・嶺・谷",
    "時分" => "夜・朝・夕・暮れ",
    "居所" => "宿・庵・垣根",
    "衣裳" => "袖・衣・砧",
    "恋" => "恋・涙・逢う",
    "旅" => "旅・旅人・行く",
  }.freeze


  def initialize(maeku, honka_candidates = [], verse_type = :tanku, constraints: {})
    @maeku            = maeku
    @honka_candidates = honka_candidates
    @verse_type       = constraints[:verse_type] || verse_type
    @constraints      = constraints
    @bui_dict         = BuiDictionary.new
  end

  def generate_tsugeku
    start_time = Time.now
    nm   = build_mecab
    pool = Rails.cache.fetch("seed_pool_v2", expires_in: 1.hour) { build_seed_pool(nm) }
    pool = filter_pool(pool)

    used_afters = []
    all_attempts = []
    result_ku   = nil

    m_season = maeku_season
    maeku_stems = KuValidator.new(@maeku).yomi_string.scan(/[ぁ-んゕゖ]{3,}/)
    m_nature = maeku_nature

    target_mora     = (@verse_type == :chouku) ? 17 : 14
    season_label    = @constraints.dig(:season_hint, :current) || SEASON_JP[m_season] || "雑"
    forbidden_bui   = @constraints[:forbidden_bui] || []
    forbidden_label = forbidden_bui.any? ? forbidden_bui.join("・") : nil

    5.times do
      seed         = pool.sample
      feedback     = nil
      wrong_streak = 0

      5.times do |attempt|
        example     = EXAMPLES[attempt % EXAMPLES.size]
        temperature = wrong_streak >= 2 ? 0.8 : 0.5
        prompt      = build_full_prompt(seed, example, feedback, season_label, forbidden_label)
        gen_start = Time.now
        raw         = OllamaClient.generate(prompt, timeout: 180, think: false, temperature: temperature)
        Rails.logger.info "[RengaGenerator] attempt: #{Time.now - gen_start}s"
        ku          = raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
        ku_ms       = morphemes_of(ku, nm)
        mora        = ku_ms.sum { |m| m[:mora] }
        is_echo     = ECHO_AFTERS.include?(ku)
        is_rep      = (ku == seed[:yomi])
        is_rep      = (ku == seed[:yomi])
        all_attempts << ku
        is_sticky       = used_afters.count(ku) >= 2 || all_attempts.count(ku) >= 3
        is_maeku_repeat = maeku_stems.any? { |w| w.include?(ku) || ku.include?(w) }

        if (mora - target_mora).abs <= 1 && !is_echo && !is_rep && !is_sticky
          result_ku = ku
          used_afters << ku
          break
        end

        wrong_streak += 1
        if wrong_streak >= 3
          seed         = pool.sample
          wrong_streak = 0
          feedback     = nil
        else
          issue   = is_echo ? "echo" : is_rep ? "鸚鵡返し" : is_sticky ? "固着" : "#{mora}音"
          message = mora > target_mora ? "もっと短く" : mora < target_mora ? "もっと長く" : "別の言葉で"
          feedback = { ku: ku, issue: issue, message: message }
        end
      end

      break if result_ku
    end

    Rails.logger.info "[RengaGenerator] total: #{Time.now - start_time}s"
    result_ku.to_s
  end

  private

  def build_mecab
    Natto::MeCab.new(userdic: USER_DIC)
  rescue => e
    Rails.logger.warn "ユーザー辞書なし: #{e.message}"
    Natto::MeCab.new
  end

  def mora_from_yomi(yomi)
    yomi.tr("ァ-ヴー", "ぁ-ゔー").chars.reject { |c| YOUON.include?(c) }.size
  end

  def count_mora_from_kana(text)
    text.gsub(/[\s\u3000]/, "").chars.reject { |c| YOUON.include?(c) }.size
  end

  def morphemes_of(text, nm)
    result = []
    nm.parse(text.gsub(/[\s\u3000]+/, "")) do |node|
      next if node.is_eos?
      f    = node.feature.split(",")
      yomi = f[7] || node.surface
      result << { surface: node.surface, yomi: yomi,
                  mora: mora_from_yomi(yomi), feature: node.feature }
    end
    result
  end

  def extract_mora_segment(morphemes, skip_mora, take_mora)
    start_idx = 0
    if skip_mora > 0
      acc = 0
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
          yomi:       phrase.map { |x| x[:yomi].tr("ァ-ヴー", "ぁ-ゔー") }.join,
          last_morph: phrase.last,
          morphemes:  phrase
        }
      end
      return nil if acc > take_mora
    end
    nil
  end

  def open_phrase?(last_morph)
    f       = last_morph[:feature].split(",")
    pos     = f[0]
    pos_sub = f[1]
    katsuyo = f[5]
    return false if pos == "動詞"   && katsuyo == "基本形"
    return false if pos == "助動詞" && katsuyo == "基本形"
    return false if pos == "助詞"   && pos_sub == "終助詞"
    return false if pos == "動詞"   && katsuyo == "体言接続"
    return false if pos == "助動詞" && katsuyo == "体言接続"
    true
  end

  def compute_season_tag(upper, lower)
    full = upper.to_s + lower.to_s
    key  = SEASON_WORDS.find { |_, words| words.any? { |w| full.include?(w) } }&.first
    key ? SEASON_JP[key] : nil
  end

  def build_seed_pool(nm)
    seeds = []
    Waka.where.not(upper_phrase_text: [nil, ""]).where.not(lower_phrase_text: [nil, ""]).each do |w|
      upper_ms = morphemes_of(w.upper_phrase_text.strip, nm)
      lower_ms = morphemes_of(w.lower_phrase_text.strip, nm)
      stag     = compute_season_tag(w.upper_phrase_text, w.lower_phrase_text)
      base     = { waka_upper: w.upper_phrase_text.to_s, waka_lower: w.lower_phrase_text.to_s, season: stag }
      upper_total = upper_ms.sum { |m| m[:mora] }
      lower_total = lower_ms.sum { |m| m[:mora] }
      if upper_total == 17
        seg = extract_mora_segment(upper_ms, 5, 7)
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "二句", bui: detect_bui(seg)) if seg && open_phrase?(seg[:last_morph])
      end
      if lower_total == 14
        seg = extract_mora_segment(lower_ms, 0, 7)
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "四句", bui: detect_bui(seg)) if seg && open_phrase?(seg[:last_morph])
        seg = extract_mora_segment(lower_ms, 7, 7)
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "結句", bui: detect_bui(seg)) if seg && open_phrase?(seg[:last_morph])
      end
    end
    Rails.logger.info "[RengaGenerator] seed pool built: #{seeds.size}件"
    seeds
  end

  def detect_bui(seg)
    seg[:morphemes].each do |m|
      bui = @bui_dict.primary_bui(m[:surface])
      return bui if bui
    end
    KIGO_BUI.each { |word, bui| return bui if seg[:surface].include?(word) }
    nil
  end

  def filter_pool(pool)
    hint = @constraints[:season_hint]

    if hint && hint[:must_switch]
      candidate = pool.reject { |s| s[:season] == hint[:current] }
      return candidate.any? ? candidate : pool
    end

    if hint && hint[:must_continue]
      candidate = pool.select { |s| s[:season] == hint[:current] }
      return candidate.any? ? candidate : pool
    end

    season    = maeku_season
    return pool unless season
    candidate = pool.select { |s| s[:season] == SEASON_JP[season] }
    candidate.any? ? candidate : pool
  end

  def maeku_season
    SEASON_WORDS.find { |_, words| words.any? { |w| @maeku.include?(w) } }&.first
  end

  def maeku_nature
    FUKA_GETSU.select { |w| @maeku.include?(w) }
  end

  def extract_hints(seed)
    full   = seed[:waka_upper] + seed[:waka_lower]
    nature = FUKA_GETSU.select { |w| full.include?(w) }
    parts  = []
    parts << "季節：#{seed[:season]}" if seed[:season]
    parts << "情景：#{nature.uniq.join("・")}" if nature.any?
    parts.empty? ? nil : parts.join(" / ")
  end

  def build_full_prompt(seed, example, feedback, season_label, forbidden_label)
    feedback_line = feedback ? "前回「#{feedback[:ku]}」は#{feedback[:issue]}。#{feedback[:message]}\n" : ""
    target_desc   = (@verse_type == :chouku) ? "五七五（17音）" : "七七（14音）"
    forbidden_bui = @constraints[:forbidden_bui] || []
    kinshi = if forbidden_bui.any?
      desc = forbidden_bui.map { |b| BUI_EXAMPLE_WORDS[b] || b }.join("・")
      "禁：#{desc}の語は避けること。\n"
    else
      ""
    end
    kigo_words = kigo_hint(season_label)
    kigo_line  = if kigo_words.any?
      "季語「#{kigo_words.join('・')}」のいずれかを必ず詠み込むこと。\n"
    elsif season_label != "雑"
      "#{season_label}の情趣を詠むこと。\n"
    else
      ""
    end

    <<~PROMPT
      前の句と合わせて短歌一首になるような続きを作れ。
      前句：#{@maeku}
      連想：#{seed[:surface]}
      季節：#{season_label}
      #{kigo_line}#{kinshi}#{feedback_line}#{target_desc}を一行だけ出力せよ。説明不要。
      続き：
    PROMPT
  end

  def kigo_hint(season_label)
    season_key = SEASON_JP.invert[season_label]
    return [] unless season_key
    forbidden_bui = @constraints[:forbidden_bui] || []
    candidates = SEASON_WORDS[season_key].reject do |w|
      bui = KIGO_BUI[w]
      bui && forbidden_bui.include?(bui)
    end
    candidates.reject { |w| @maeku.include?(w) }.shuffle.first(2)
  end
end
