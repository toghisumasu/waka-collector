# frozen_string_literal: true
require "natto"

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

  SEASON_WORDS = {
    spring: %w[春 霞 梅 桜 鶯 柳 蛙 燕 桃 朧 若草 菜の花 山吹 かすみ うぐいす わらび ふきのとう すみれ たんぽぽ よもぎ],
    summer: %w[夏 郭公 ほととぎす 蛍 五月雨 蓮 卯の花 青葉 緑 時鳥 さみだれ あやめ しょうぶ],
    autumn: %w[秋 月 紅葉 もみじ もみち 露 雁 鹿 萩 菊 竜田 嵐 時雨 霧 しぐれ きり おみなえし ききょう],
    winter: %w[冬 雪 霜 氷 枯 千鳥 鷺 さむ みぞれ しも かれの]
  }.freeze

  FUKA_GETSU = %w[花 鳥 風 月 雪 霞 波 雲 雨 山 川 海 野 里 露 松 竹 草 水 煙 霧].freeze
  SEASON_JP  = { spring: "春", summer: "夏", autumn: "秋", winter: "冬" }.freeze

  def initialize(maeku, honka_candidates = [], verse_type = :tanku)
    @maeku            = maeku
    @honka_candidates = honka_candidates
    @verse_type       = verse_type
  end

  def generate_tsugeku
    start_time = Time.now
    nm   = build_mecab
    pool = Rails.cache.fetch("seed_pool_v1", expires_in: 1.hour) { build_seed_pool(nm) }
    pool = filter_pool(pool)

    used_afters = []
    all_attempts = []
    result_ku   = nil

    m_season = maeku_season
    maeku_stems = KuValidator.new(@maeku).yomi_string.scan(/[ぁ-んゕゖ]{3,}/)
    m_nature = maeku_nature

    5.times do
      seed         = pool.sample
      hints        = extract_hints(seed)
      feedback     = nil
      wrong_streak = 0

      5.times do |attempt|
        example     = EXAMPLES[attempt % EXAMPLES.size]
        temperature = wrong_streak >= 2 ? 0.8 : 0.5
        prompt      = build_after_prompt(seed, example, feedback, hints, m_nature)
        gen_start = Time.now
        raw         = OllamaClient.generate(prompt, timeout: 120, think: false, temperature: temperature)
        Rails.logger.info "[RengaGenerator] attempt: #{Time.now - gen_start}s"
        ku          = raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
        mora        = count_mora_from_kana(ku)
        has_kanji   = ku.match?(/[^\u3040-\u309F\u3099-\u309C\s]/)
        is_echo     = ECHO_AFTERS.include?(ku)
        is_rep      = (ku == seed[:yomi])
        all_attempts << ku
        is_sticky       = used_afters.count(ku) >= 2 || all_attempts.count(ku) >= 3
        is_maeku_repeat = maeku_stems.any? { |w| w.include?(ku) || ku.include?(w) }

        target_mora = (@verse_type == :chouku) ? 5 : 7
        if mora == target_mora && !has_kanji && !is_echo && !is_rep && !is_sticky && !is_maeku_repeat
          result_ku = "#{seed[:surface]}#{ku}"
          used_afters << ku
          break
        end

        wrong_streak += 1
        if wrong_streak >= 3
          seed         = pool.sample
          wrong_streak = 0
          feedback     = nil
        else
          issue   = has_kanji ? "漢字混入" : is_echo ? "echo" : is_rep ? "鸚鵡返し" : is_sticky ? "固着" : is_maeku_repeat ? "前句重複" : "#{mora}音"
          message = mora > 7 ? "もっと短く" : mora < 7 ? "もっと長く" : "別の言葉で"
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
          last_morph: phrase.last
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
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "二句") if seg && open_phrase?(seg[:last_morph])
      end
      if lower_total == 14
        seg = extract_mora_segment(lower_ms, 0, 7)
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "四句") if seg && open_phrase?(seg[:last_morph])
        seg = extract_mora_segment(lower_ms, 7, 7)
        seeds << base.merge(surface: seg[:surface], yomi: seg[:yomi], position: "結句") if seg && open_phrase?(seg[:last_morph])
      end
    end
    Rails.logger.info "[RengaGenerator] seed pool built: #{seeds.size}件"
    seeds
  end

  def filter_pool(pool)
    season = maeku_season
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

  def build_after_prompt(seed, example, feedback, hints, m_nature)
    maeku_hint = m_nature.any? ? "前句の情景：#{m_nature.join("・")}" : nil
    hint_parts = [maeku_hint, hints ? "元の和歌より：#{hints}" : nil].compact
    hint_line  = hint_parts.any? ? "【付合の手がかり】#{hint_parts.join(" / ")}\n" : ""
    feedback_line = feedback ? "【やり直し】前回「#{feedback[:ku]}」は #{feedback[:issue]}。#{feedback[:message]}\n" : ""
    if @verse_type == :chouku
      <<~PROMPT
        あなたは連歌の執筆役です。
        【前句】
        #{@maeku}
        #{hint_line}【指示】
        長句（五七五）の第2句はすでに決まっています。
        第3句の5音のみをひらがなで出力してください。
        第2句の言葉は出力しないこと。
        第2句を「主部・条件」、第3句をそれを受ける「結び」として完成させてください。
        例：「#{example[:before]}」→「#{example[:after]}」
        第2句（決定済み）：#{seed[:surface]}
        #{feedback_line}【出力ルール】
        - ひらがなのみで5音ちょうどを1行で出力する。
        - 第2句の言葉を繰り返さない。
        - 例文の言葉（「#{example[:after]}」）をそのままコピーしない。
        - 説明・記号・句読点は一切出力しない。
        第3句の5音：
      PROMPT
    else
      <<~PROMPT
        あなたは連歌の執筆役です。
        【前句】
        #{@maeku}
        #{hint_line}【指示】
        短句（七七）の前半はすでに決まっています。
        後半の7音のみをひらがなで出力してください。
        前半の言葉は出力しないこと。
        前半を「主部・条件・理由」、後半をそれを受ける「述部」として完成させてください。
        例：「#{example[:before]}」→「#{example[:after]}」
        前半（決定済み）：#{seed[:surface]}
        #{feedback_line}【出力ルール】
        - ひらがなのみで7音ちょうどを1行で出力する。
        - 前半の言葉を繰り返さない。
        - 例文の言葉（「#{example[:after]}」）をそのままコピーしない。
        - 説明・記号・句読点は一切出力しない。
        後半の7音：
      PROMPT
    end
  end
end
