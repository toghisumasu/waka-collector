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

  # 其の三十二 Step B-3: 字足らず時、不足モーラ数に応じて句末に足す
  # 連歌的文末表現の候補（LLMへの具体的な調整手段の提示に使う）
  ENDING_BY_MORA = {
    1 => ["や", "か", "ぬ", "に"],
    2 => ["かな", "けり", "らむ", "なり"],
    3 => ["ぞかし", "ぬかな", "にけり"],
    4 => ["にけらし", "ぬるかな", "たるかな"]
  }.freeze

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
    @verse_history    = constraints[:verse_history] || []
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
    season_hint     = @constraints[:season_hint]
    forbidden_bui   = @constraints[:forbidden_bui] || []
    forbidden_label = forbidden_bui.any? ? forbidden_bui.join("・") : nil

    # 其の三十一 Step C-3・其の三十二 Step B-3改: mora不一致が連続すると
    # 通常のfeedback文言では固着（同一文言の再送）が解消しないケースがあり、
    # tools不要の複数ターン会話（chat）に切り替え、自己認識→概念確認→
    # 実際の詠み直し、の3段階を踏ませることで局面打開を狙う。streakは
    # generate_tsugeku呼び出し全体（seed再抽選をまたいで）で維持する。
    mora_error_streak     = 0
    past_mora_error_words = []
    last_mora_count       = nil

    # 其の三十六: 一巻の履歴（verse_history）との完全一致・類似が連続した際、
    # mora_error_streakと同じ構造でSocratic対話にエスカレーションする。
    repeat_streak     = 0
    past_repeat_words = []

    5.times do
      seed         = pool.sample
      feedback     = nil
      wrong_streak = 0

      5.times do |attempt|
        example     = EXAMPLES[attempt % EXAMPLES.size]
        temperature = wrong_streak >= 2 ? 0.8 : 0.5

        # 字余り方向はstreak>=2、字足らず方向はstreak>=3で発動
        # （其の三十二 Step B-3改：字足らず側は閾値を1段引き上げている）
        if mora_error_streak >= 2 && (last_mora_count > target_mora || mora_error_streak >= 3)
          raw = OllamaClient.chat(
            socratic_mora_messages(last_mora_count, target_mora, past_mora_error_words),
            think: false, timeout: 300
          )
        elsif repeat_streak >= 2
          raw = OllamaClient.chat(
            socratic_repeat_messages(past_repeat_words, target_mora),
            think: false, timeout: 300
          )
        else
          season_label = if season_hint && season_hint[:must_switch]
            seed[:season] || "雑"
          else
            season_hint&.dig(:current) || SEASON_JP[m_season] || "雑"
          end
          prompt    = build_full_prompt(seed, example, feedback, season_label, forbidden_label)
          gen_start = Time.now
          raw       = OllamaClient.generate(prompt, timeout: 180, think: false, temperature: temperature)
          Rails.logger.info "[RengaGenerator] attempt: #{Time.now - gen_start}s"
        end

        ku    = raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
        ku_ms = morphemes_of(ku, nm)
        mora  = ku_ms.sum { |m| m[:mora] }

        if (mora - target_mora).abs > 1
          mora_error_streak += 1
          past_mora_error_words << ku
          past_mora_error_words.shift while past_mora_error_words.size > 3
          last_mora_count = mora

          wrong_streak += 1
          if wrong_streak >= 3
            seed         = pool.sample
            wrong_streak = 0
            feedback     = nil
          else
            feedback = { ku: ku, issue: "#{mora}音", message: mora_feedback_message(mora, target_mora) }
          end
          next
        end

        mora_error_streak = 0

        is_echo     = ECHO_AFTERS.include?(ku)
        is_rep      = (ku == seed[:yomi])
        all_attempts << ku
        is_sticky       = used_afters.count(ku) >= 2 || all_attempts.count(ku) >= 3
        is_maeku_repeat = maeku_stems.any? { |w| w.include?(ku) || ku.include?(w) }

        is_history_repeat = history_repeat?(ku)
        if is_history_repeat
          repeat_streak += 1
          past_repeat_words << ku
          past_repeat_words.shift while past_repeat_words.size > 3
        else
          repeat_streak = 0
        end

        if !is_echo && !is_rep && !is_sticky && !is_history_repeat
          result_ku = ku
          used_afters << ku
          break
        end

        wrong_streak += 1
        if wrong_streak >= 3
          seed         = pool.sample
          wrong_streak = 0
          feedback     = nil
        elsif is_echo || is_rep || is_sticky
          issue    = is_echo ? "echo" : is_rep ? "鸚鵡返し" : "固着"
          feedback = { ku: ku, issue: issue, message: "別の言葉で" }
        else
          feedback = { ku: ku, issue: "既出", message: "別の表現で" }
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
    forbidden_bui = @constraints[:forbidden_bui] || []

    # bui フィルタ：部立が判明しており禁止リストに含まれるシードを除外
    # bui: nil は「部立なし」として通過させる
    if forbidden_bui.any?
      filtered = pool.reject { |s| s[:bui] && forbidden_bui.include?(s[:bui]) }
      pool = filtered.any? ? filtered : pool
    end

    # 以下は既存ロジックそのまま
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

  # 通常経路（build_full_prompt）でのmora不一致feedback文言。
  # 其の三十二 Step B-3: 字足らずは不足モーラ数に応じた文末表現の
  # 具体例を提示し、方向だけでなく具体的な調整手段を把握できるようにする。
  def mora_feedback_message(mora, target_mora)
    if mora > target_mora
      "#{target_mora}音になるよう、もっと短くしてください"
    else
      deficit    = target_mora - mora
      candidates = ENDING_BY_MORA[deficit] || []
      if candidates.any?
        "#{mora}音で#{deficit}音足りません。" \
        "句末に#{candidates.map { |c| "「#{c}」" }.join("、")}などを" \
        "足すと#{target_mora}音になります。"
      else
        "#{target_mora}音になるよう、もっと長くしてください"
      end
    end
  end

  # 其の三十六: 一巻の履歴（verse_history、tsugeku本文の配列）との
  # 完全一致・類似検知。distance 0 = 完全一致、
  # distance <= max(文字数×0.3, 3) = 類似（一語違い相当）。
  # script/dryrun_hyakuin.rbで検証済みの実装をそのまま移植している。
  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?

    costs = Array(0..b.length)
    a.each_char.with_index do |ca, i|
      costs[0] = i + 1
      nw = i
      b.each_char.with_index do |cb, j|
        cur = costs[j + 1]
        costs[j + 1] = ca == cb ? nw : ([costs[j], costs[j + 1], nw].min + 1)
        nw = cur
      end
    end
    costs[b.length]
  end

  def history_repeat?(word)
    return false if @verse_history.empty?
    return false if word.nil? || word.strip.empty?

    best_dist = nil
    @verse_history.each do |past|
      next if past.nil? || past.strip.empty?
      d = levenshtein(word, past)
      best_dist = d if best_dist.nil? || d < best_dist
      break if best_dist.zero?
    end
    return false if best_dist.nil?

    threshold = [(word.length * 0.3).ceil, 3].max
    best_dist <= threshold
  end

  # 其の三十一 Step C-3・其の三十二 Step B-3改: mora_error_streakが
  # 閾値に達したときのSocratic三段階対話（自己認識→概念確認→詠み直し）。
  # 字余り方向は「雑（無季）への転換」、字足らず方向は「文末表現の追加」で
  # 局面打開を促す（季を強制するのは字余り方向のみ）。
  def socratic_mora_messages(last_mora_count, target_mora, past_words)
    if last_mora_count > target_mora
      [
        { role: "user", content: "あなたはいま、同じような句を繰り返しています。" \
                                  "直前の候補「#{past_words.last}」は" \
                                  "#{last_mora_count}音で、目標の#{target_mora}音に" \
                                  "合っていません。行き詰まっていることを認識してください。" },
        { role: "assistant", content: "はい、行き詰まっています。同じような句を繰り返しており、" \
                                       "字数が合っていません。局面を打開する必要があります。" },
        { role: "user", content: "連歌では、季語（春・夏・秋・冬の語）を使う句と、" \
                                  "季語を使わない「雑（ぞう）」の句があります。" \
                                  "雑の句は季節に縛られず自由に詠めます。" \
                                  "局面打開には雑の句が有効なことがあります。" \
                                  "理解できましたか？" },
        { role: "assistant", content: "はい、理解しました。雑の句とは季語を含まない句で、" \
                                       "季節に縛られず詠むことができます。" },
        { role: "user", content: "では局面打開のため、雑の句として全く新しい言葉で" \
                                  "#{target_mora}音の付け句を詠んでください。\n" \
                                  "前句：#{@maeku}\n" \
                                  "これまでの候補（再使用禁止）：#{past_words.join('、')}\n" \
                                  "#{target_mora}音を一行だけ出力してください。説明不要。" }
      ]
    else
      deficit     = target_mora - last_mora_count
      candidates  = ENDING_BY_MORA[deficit] || []
      ending_hint = candidates.any? ?
        "句末に#{candidates.map { |c| "「#{c}」" }.join("、")}などを足すと自然です。" :
        "句末に文末表現を加えて長くしてください。"

      [
        { role: "user", content: "あなたはいま、同じような句を繰り返しています。" \
                                  "直前の候補「#{past_words.last}」は" \
                                  "#{last_mora_count}音で、目標の#{target_mora}音より" \
                                  "#{deficit}音足りません。行き詰まっていることを認識してください。" },
        { role: "assistant", content: "はい、行き詰まっています。#{deficit}音足りず、" \
                                       "同じような句を繰り返しています。局面を打開する必要があります。" },
        { role: "user", content: "連歌では句の末尾に文末表現を加えて音数を整えます。" \
                                  "#{deficit}音足りない場合、#{ending_hint}" \
                                  "理解できましたか？" },
        { role: "assistant", content: "はい、理解しました。句末に文末表現を加えて" \
                                       "#{target_mora}音に整えます。" },
        { role: "user", content: "では句末に文末表現を加えて、全く新しい言葉で" \
                                  "#{target_mora}音の付け句を詠んでください。\n" \
                                  "前句：#{@maeku}\n" \
                                  "これまでの候補（再使用禁止）：#{past_words.join('、')}\n" \
                                  "#{target_mora}音を一行だけ出力してください。説明不要。" }
      ]
    end
  end

  # 其の三十六: 履歴（一巻全体）との一致・類似がverse_no内で連続した際の
  # Socratic三段階対話。socratic_mora_messagesの字余り方向と同じ構造を流用し、
  # 内容を「雑（無季）へ」から「既出表現を避けよ」に差し替えている。
  def socratic_repeat_messages(past_words, target_mora)
    [
      { role: "user", content: "あなたはいま、この百韻の中で既に詠まれた句と同じか、" \
                                "非常によく似た句を繰り返しています。" \
                                "直前の候補「#{past_words.last}」がそれです。" \
                                "行き詰まっていることを認識してください。" },
      { role: "assistant", content: "はい、行き詰まっています。既に詠まれた句と同じか似た句を" \
                                     "繰り返しており、局面を打開する必要があります。" },
      { role: "user", content: "連歌では、一巻の中で既出の語句を繰り返すことは避けるべきとされています。" \
                                "既出の語から離れ、全く異なる語彙・言い回しを選ぶことが" \
                                "局面打開に有効です。理解できましたか？" },
      { role: "assistant", content: "はい、理解しました。既出の語句を避け、全く新しい語彙で詠みます。" },
      { role: "user", content: "では既出の表現を避け、全く新しい言葉で" \
                                "#{target_mora}音の付け句を詠んでください。\n" \
                                "前句：#{@maeku}\n" \
                                "これまでの候補（再使用禁止）：#{past_words.join('、')}\n" \
                                "#{target_mora}音を一行だけ出力してください。説明不要。" }
    ]
  end
end
