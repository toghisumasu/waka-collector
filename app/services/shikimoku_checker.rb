# frozen_string_literal: true

require "yaml"

# ShikimokuChecker ── 式目ガードレール（句去 + 句数チェック・純Ruby）
#
# 責務①：句去（くさり）── 同じ部立を再び使うまでに間に挟むべき句数の確認
# 責務②：句数（くかず）── 同じ季・部立が連続できる上限、および春・秋の最短規制
#
# ─ verse（句情報）の形式 ────────────────────────────────
# Hash { bui: Array<String>, season: String | nil }
#   bui    … 部立の集合  例: ["降物", "聳物"]
#   season … 季           例: "春" / "秋" / "夏" / "冬" / nil（雑・無季）
#
# ─ 将来の DB 連携 ────────────────────────────────────────
# 一座の句が DB で管理されるようになったとき、以下のように渡せる：
#   history = Renga.chain.map { |r| { bui: r.bui_list, season: r.season } }
#   checker.all_violations(history, candidate_verse)
# DB コールはこのクラスの外で行い、ここには配列として渡す。
# このクラス自体は LLM・MeCab・Rails いずれにも依存しない（純 Ruby）。
# ────────────────────────────────────────────────────────

class ShikimokuChecker
  DEFAULT_KUZARI_PATH =
    if defined?(Rails)
      Rails.root.join("app/data/kuzari_rules.yml").to_s
    else
      File.expand_path("../data/kuzari_rules.yml", __dir__)
    end

  DEFAULT_KUKAZO_PATH =
    if defined?(Rails)
      Rails.root.join("app/data/kukazo_rules.yml").to_s
    else
      File.expand_path("../data/kukazo_rules.yml", __dir__)
    end

  DEFAULT_ICHIZA_PATH =
    if defined?(Rails)
      Rails.root.join("app/data/ichiza_ichiku_words.yml").to_s
    else
      File.expand_path("../data/ichiza_ichiku_words.yml", __dir__)
    end

  attr_reader :rules, :kukazo_rules, :ichiza_words

  # rules / kukazo_rules / ichiza_words はテスト時に直接注入できる（ファイル不要）。
  def initialize(rules: nil, kukazo_rules: nil, ichiza_words: nil,
                 rules_path: DEFAULT_KUZARI_PATH,
                 kukazo_path: DEFAULT_KUKAZO_PATH,
                 ichiza_path: DEFAULT_ICHIZA_PATH)
    @rules        = rules        || YAML.load_file(rules_path)
    @kukazo_rules = kukazo_rules || YAML.load_file(kukazo_path)
    raw_ichiza    = ichiza_words || (File.exist?(ichiza_path.to_s) ? YAML.load_file(ichiza_path) : {})
    @ichiza_words = raw_ichiza.is_a?(Hash) ? raw_ichiza.keys : Array(raw_ichiza)
  end

  # ══════════════════════════════════════════════════════
  #  句去（くさり）チェック ── 後方互換・Array<Array<String>> 形式
  # ══════════════════════════════════════════════════════

  # history_bui   : Array<Array<String>>  各句の部立集合（古い順）
  # candidate_bui : Array<String>         付けようとする句の部立集合
  # 返り値: Array<Hash>  { bui:, required:, actual:, last_pos: }
  #
  # 植物細分化オプション:
  #   history_plant_types : Array<String|nil>  各句の plant_type（"flower"/"grass"/"tree"/nil）
  #   candidate_plant_type: String|nil         候補句の plant_type
  #   同種間は kuzari_rules の default 句去、異種間は cross 句去を適用。
  #   どちらかが nil の場合は default を使用（後方互換）。
  def kuzari_violations(history_bui, candidate_bui, bui_dict: nil, history_words: [],
                        candidate_word: nil, history_plant_types: [], candidate_plant_type: nil)
    n = history_bui.size
    violations = []

    Array(candidate_bui).uniq.each do |bui|
      rule = @rules[bui]
      next unless rule

      # ルールが Hash（植物など細分化済み）か Integer かで基本句去を取得
      base_interval = rule.is_a?(Hash) ? rule["default"] : rule

      cand_taiyo = bui_dict&.taiyo(candidate_word)

      j = n.downto(1).find do |pos|
        next false unless Array(history_bui[pos - 1]).include?(bui)
        if bui_dict && cand_taiyo && history_words[pos - 1]
          hist_taiyo = bui_dict.taiyo(history_words[pos - 1])
          next false if hist_taiyo != cand_taiyo
        end
        true
      end
      next if j.nil?
      next if j == n

      # 植物細分化: 両句に plant_type が設定されていて異種なら cross 句去を使用
      interval = base_interval
      if rule.is_a?(Hash) && candidate_plant_type && history_plant_types[j - 1]
        if candidate_plant_type != history_plant_types[j - 1]
          interval = rule["cross"]
        end
      end

      between = n - j
      next if between >= interval - 1  # 古典の数え年方式: 差=interval で合法

      violations << { bui: bui, required: interval, actual: between, last_pos: j }
    end

    violations
  end

  def kuzari_ok?(history_bui, candidate_bui)
    kuzari_violations(history_bui, candidate_bui).empty?
  end

  # ══════════════════════════════════════════════════════
  #  句数（くかず）チェック ── Hash 形式
  # ══════════════════════════════════════════════════════

  # 検査①: 季節・部立の連続上限
  #   春・秋・恋 = 五句 / 夏・冬・旅・述懐・神祇・釈教・山類・水辺・居所 = 三句
  #
  # 検査②: 春・秋の最短規制（転換時のみ発動）
  #   「春秋の句不至三句者不用之」（連歌新式）
  #   直前句の季が春/秋で、候補句が別の季へ転換する場合に確認する。
  #
  # 返り値: Array<Hash>
  #   連続上限超過: { type: :kukazo_over,  target: :bui|:season,
  #                   bui:|season:,  streak:, max: }
  #   最短規制違反: { type: :kukazo_under, season:, streak:, min: }
  def kukazo_violations(history, candidate)
    violations   = []
    cand_season  = candidate[:season]
    prev_season  = history.last&.dig(:season)

    # 検査①a: 部立の連続上限
    Array(candidate[:bui]).uniq.each do |bui|
      bui_rule = @kukazo_rules.dig("bui", bui)
      next unless bui_rule&.key?("max")

      streak = current_bui_streak(history, bui) + 1  # 候補を含む連続数
      if streak > bui_rule["max"]
        violations << { type: :kukazo_over, target: :bui,
                        bui: bui, streak: streak, max: bui_rule["max"] }
      end
    end

    # 検査①b: 季節の連続上限（雑は制限なし）
    if cand_season
      season_rule = @kukazo_rules.dig("seasons", cand_season)
      if season_rule&.key?("max")
        streak = current_season_streak(history, cand_season) + 1
        if streak > season_rule["max"]
          violations << { type: :kukazo_over, target: :season,
                          season: cand_season, streak: streak, max: season_rule["max"] }
        end
      end
    end

    # 検査②: 春・秋の最短規制（転換時のみ）
    # prev_season が春/秋 かつ 候補が別の季（または雑）へ転換するとき確認。
    if prev_season && prev_season != cand_season
      min_req = @kukazo_rules.dig("seasons", prev_season, "min")
      if min_req
        streak = current_season_streak(history, prev_season)
        if streak < min_req
          violations << { type: :kukazo_under,
                          season: prev_season, streak: streak, min: min_req }
        end
      end
    end

    violations
  end

  def kukazo_ok?(history, candidate)
    kukazo_violations(history, candidate).empty?
  end

  # ══════════════════════════════════════════════════════
  #  統合チェック：句去 + 句数（Hash 形式）
  # ══════════════════════════════════════════════════════

  def all_violations(history, candidate, bui_dict: nil)
    history_bui         = history.map { |v| Array(v[:bui]) }
    history_words       = history.map { |v| v[:word] }
    history_plant_types = history.map { |v| v[:plant_type]&.to_s }
    candidate_bui       = Array(candidate[:bui])
    candidate_word      = candidate[:word]
    candidate_plant_type = candidate[:plant_type]&.to_s
    kuzari_violations(history_bui, candidate_bui,
                      bui_dict: bui_dict,
                      history_words: history_words,
                      candidate_word: candidate_word,
                      history_plant_types: history_plant_types,
                      candidate_plant_type: candidate_plant_type) +
      kukazo_violations(history, candidate)
  end

  def all_ok?(history, candidate)
    all_violations(history, candidate).empty?
  end

  # ══════════════════════════════════════════════════════
  #  連鎖全体を先頭から逐次検査
  # ══════════════════════════════════════════════════════

  # chain: Array<Hash>         → 句去 + 句数（統合・推奨）
  #        Array<Array<String>> → 句去のみ（後方互換）
  def scan_chain(chain, bui_dict: nil)
    results = []
    chain.each_with_index do |candidate, i|
      history = chain[0...i]
      if candidate.is_a?(Hash)
        all_violations(history, candidate, bui_dict: bui_dict).each { |v| results << v.merge(pos: i + 1) }
      else
        kuzari_violations(history, candidate, bui_dict: bui_dict).each { |v| results << v.merge(pos: i + 1) }
      end
    end
    results
  end

  # ══════════════════════════════════════════════════════
  #  ストリークカウンタ（DB 連携後も直接呼べる public メソッド）
  # ══════════════════════════════════════════════════════

  # history 末尾から、同じ部立を含む句が何句連続しているか返す。
  # DB 連携後: history = Renga.chain.map { |r| { bui: r.bui_list, season: r.season } }
  def current_bui_streak(history, bui)
    history.reverse_each
           .take_while { |v| Array(v[:bui]).include?(bui) }
           .length
  end

  # history 末尾から、同じ季の句が何句連続しているか返す。
  def current_season_streak(history, season)
    history.reverse_each
           .take_while { |v| v[:season] == season }
           .length
  end

  # ══════════════════════════════════════════════════════
  #  長短交互チェック（Phase 8-2）
  # ══════════════════════════════════════════════════════
  #
  # verse[:verse_type] = :chouku（長句 5-7-5）or :tanku（短句 7-7）
  # 発句は :chouku 固定。隣接する2句が同じ verse_type なら違反。
  # verse_type キーのない句はスキップ（型未確定の句と混在可）。

  # history: Array<Hash>  直前までの句列
  # candidate: Hash       今付けようとする句
  # 返り値: Array<Hash> { type: :chotan_chigai, pos:, verse_type:, expected: }
  def chotan_violations(history, candidate)
    return [] unless candidate.is_a?(Hash) && candidate[:verse_type]

    prev = history.reverse_each.find { |v| v.is_a?(Hash) && v[:verse_type] }
    return [] unless prev

    return [] if prev[:verse_type] != candidate[:verse_type]

    expected = (candidate[:verse_type] == :chouku) ? :tanku : :chouku
    [{ type: :chotan_chigai,
       verse_type: candidate[:verse_type],
       expected: expected }]
  end

  def chotan_ok?(history, candidate)
    chotan_violations(history, candidate).empty?
  end

  # ══════════════════════════════════════════════════════
  #  定座チェック（月・花）
  # ══════════════════════════════════════════════════════
  #
  # verse[:tsuki] = true … その句に「月」が詠まれている
  # verse[:hana]  = true … その句に「花（桜）」が詠まれている
  #
  # faces: Array<Hash> { name:, range: Range<Integer>(1-based), req: bool }
  #   req: false の面はチェックしない（名残裏免除など）
  #
  # 月チェック: 各面（面=表/裏の区切り）に月を1句以上
  # 花チェック: 各折（折単位）に花を1句以上

  def teiza_tsuki_violations(chain, faces)
    faces.each_with_object([]) do |face, violations|
      next unless face[:req]
      verses = chain[(face[:range].min - 1)..(face[:range].max - 1)]
      unless verses.any? { |v| v.is_a?(Hash) && v[:tsuki] }
        violations << { type: :teiza_tsuki, fold: face[:name], range: face[:range] }
      end
    end
  end

  def teiza_hana_violations(chain, folds)
    folds.each_with_object([]) do |fold, violations|
      verses = chain[(fold[:range].min - 1)..(fold[:range].max - 1)]
      unless verses.any? { |v| v.is_a?(Hash) && v[:hana] }
        violations << { type: :teiza_hana, fold: fold[:name], range: fold[:range] }
      end
    end
  end

  # scan_chain に長短交互チェックを統合（verse_type があるときのみ）
  def scan_chain_with_chotan(chain, bui_dict: nil)
    results = []
    chain.each_with_index do |candidate, i|
      history = chain[0...i]
      if candidate.is_a?(Hash)
        all_violations(history, candidate, bui_dict: bui_dict).each { |v| results << v.merge(pos: i + 1) }
        chotan_violations(history, candidate).each { |v| results << v.merge(pos: i + 1) }
      else
        kuzari_violations(history, candidate, bui_dict: bui_dict).each { |v| results << v.merge(pos: i + 1) }
      end
    end
    results
  end

  # ══════════════════════════════════════════════════════
  #  一座一句物チェック
  # ══════════════════════════════════════════════════════

  # history      : Array<Hash>    確定済みの句列（候補を含まない）
  # candidate    : Hash           今付けようとする句
  # ichiza_words : Array<String>  一座一句物語のリスト（省略時は初期化時のリストを使用）
  # 返り値: Array<Hash> { type: :ichiza_duplicate, word:, first_pos:, pos: }
  #
  # 候補句が history 内に既出の一座一句物語を含む場合のみ違反を返す。
  # history 内部同士の重複は検査しない（確定済み履歴の再検査は行わない）。
  # 照合は verse[:word].to_s への部分文字列マッチで行う。
  # 花（一座四句物）は本リストに含めず、teiza_hana_violations で管理する。
  def ichiza_violations(history, candidate, ichiza_words = @ichiza_words)
    cand_text = candidate.is_a?(Hash) ? candidate[:word].to_s : candidate.to_s
    hist_seen = {}
    history.each_with_index do |verse, i|
      text = verse.is_a?(Hash) ? verse[:word].to_s : verse.to_s
      Array(ichiza_words).each do |iw|
        hist_seen[iw] ||= i + 1 if text.include?(iw)
      end
    end
    violations = []
    Array(ichiza_words).each do |iw|
      if cand_text.include?(iw) && hist_seen.key?(iw)
        violations << { type: :ichiza_duplicate, word: iw, first_pos: hist_seen[iw], pos: history.size + 1 }
      end
    end
    violations
  end

  def ichiza_ok?(history, candidate, ichiza_words = @ichiza_words)
    ichiza_violations(history, candidate, ichiza_words).empty?
  end

  # ══════════════════════════════════════════════════════
  #  違反の人間可読表示
  # ══════════════════════════════════════════════════════

  def self.describe(violation)
    pos_str = violation[:pos] ? "#{violation[:pos]}句目：" : ""
    case violation[:type]
    when :ichiza_duplicate
      "#{pos_str}一座一句物「#{violation[:word]}」が#{violation[:first_pos]}句目に続き再出（一座一句・二度目不可）"
    when :teiza_tsuki
      "#{pos_str}面「#{violation[:fold]}」（#{violation[:range]}句）に月なし"
    when :teiza_hana
      "#{pos_str}折「#{violation[:fold]}」（#{violation[:range]}句）に花なし"
    when :chotan_chigai
      type_ja = violation[:verse_type] == :chouku ? "長句" : "短句"
      exp_ja  = violation[:expected]   == :chouku ? "長句" : "短句"
      "#{pos_str}#{type_ja}が連続（次は#{exp_ja}が必要）"
    when :kukazo_over
      if violation[:season]
        "#{pos_str}季「#{violation[:season]}」が#{violation[:streak]}句連続（上限#{violation[:max]}句）"
      else
        "#{pos_str}部立「#{violation[:bui]}」が#{violation[:streak]}句連続（上限#{violation[:max]}句）"
      end
    when :kukazo_under
      "#{pos_str}季「#{violation[:season]}」が#{violation[:streak]}句で転換（最低#{violation[:min]}句必要）"
    when :generation_failed
      reason = violation[:reason] ? "（理由: #{violation[:reason]}）" : ""
      "#{pos_str}句生成に失敗しました#{reason}"
    when :mora_error
      "#{pos_str}#{violation[:desc] || '音数不一致'}"
    else
      # :type キーなし → 句去違反（後方互換）
      v = violation
      "#{pos_str}部立「#{v[:bui]}」が#{v[:last_pos]}句目から" \
        "間#{v[:actual]}句で再出（#{v[:required]}句去・不足#{v[:required] - v[:actual]}）"
    end
  end
  # -------------------------------------------------------
  # next_constraints: 次句生成のための制約サマリーを返す
  # @param history [Array<Hash>]  verse Hash の配列（候補句は含まない）
  # @return [Hash] { verse_type:, forbidden_bui:, season_hint: }
  # -------------------------------------------------------
  def next_constraints(history, bui_dict: nil)
    {
      verse_type:    next_verse_type(history),
      forbidden_bui: compute_forbidden_bui(history),
      season_hint:   compute_season_hint(history)
    }
  end

  private

  def next_verse_type(history)
    return :tanku if history.empty?
    last_type = history.last[:verse_type]
    return :tanku if last_type.nil?
    last_type == :chouku ? :tanku : :chouku
  end

  def compute_forbidden_bui(history)
    n = history.size
    forbidden = []
    @rules.each do |bui, rule|
      interval = rule.is_a?(Hash) ? rule["default"] : rule
      j = (1..n).to_a.reverse.find { |pos| history[pos - 1][:bui]&.include?(bui) }
      next unless j
      forbidden << bui if (n - j) < interval - 1
    end
    forbidden.uniq
  end

  def compute_season_hint(history)
    current = history.last&.dig(:season)
    return { current: nil, count: 0, must_continue: false, must_switch: false }       if current.nil? || current == "\u96d1"
    count = 0
    history.reverse_each { |v| break if v[:season] != current; count += 1 }
    rules   = @kukazo_rules.dig("seasons", current) || {}
    max_val = rules["max"]
    min_val = rules["min"]
    {
      current:       current,
      count:         count,
      must_continue: min_val ? count < min_val : false,
      must_switch:   max_val ? count >= max_val : false
    }
  end

end

