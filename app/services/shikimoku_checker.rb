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

  attr_reader :rules, :kukazo_rules

  # rules / kukazo_rules はテスト時に直接注入できる（ファイル不要）。
  def initialize(rules: nil, kukazo_rules: nil,
                 rules_path: DEFAULT_KUZARI_PATH,
                 kukazo_path: DEFAULT_KUKAZO_PATH)
    @rules        = rules        || YAML.load_file(rules_path)
    @kukazo_rules = kukazo_rules || YAML.load_file(kukazo_path)
  end

  # ══════════════════════════════════════════════════════
  #  句去（くさり）チェック ── 後方互換・Array<Array<String>> 形式
  # ══════════════════════════════════════════════════════

  # history_bui   : Array<Array<String>>  各句の部立集合（古い順）
  # candidate_bui : Array<String>         付けようとする句の部立集合
  # 返り値: Array<Hash>  { bui:, required:, actual:, last_pos: }
  def kuzari_violations(history_bui, candidate_bui, bui_dict: nil, history_words: [], candidate_word: nil)
    n = history_bui.size
    violations = []

    Array(candidate_bui).uniq.each do |bui|
      interval = @rules[bui]
      next unless interval

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
    history_bui   = history.map { |v| Array(v[:bui]) }
    history_words = history.map { |v| v[:word] }
    candidate_bui  = Array(candidate[:bui])
    candidate_word = candidate[:word]
    kuzari_violations(history_bui, candidate_bui,
                      bui_dict: bui_dict,
                      history_words: history_words,
                      candidate_word: candidate_word) +
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
  #  違反の人間可読表示
  # ══════════════════════════════════════════════════════

  def self.describe(violation)
    pos_str = violation[:pos] ? "#{violation[:pos]}句目：" : ""
    case violation[:type]
    when :kukazo_over
      if violation[:season]
        "#{pos_str}季「#{violation[:season]}」が#{violation[:streak]}句連続（上限#{violation[:max]}句）"
      else
        "#{pos_str}部立「#{violation[:bui]}」が#{violation[:streak]}句連続（上限#{violation[:max]}句）"
      end
    when :kukazo_under
      "#{pos_str}季「#{violation[:season]}」が#{violation[:streak]}句で転換（最低#{violation[:min]}句必要）"
    else
      # :type キーなし → 句去違反（後方互換）
      v = violation
      "#{pos_str}部立「#{v[:bui]}」が#{v[:last_pos]}句目から" \
        "間#{v[:actual]}句で再出（#{v[:required]}句去・不足#{v[:required] - v[:actual]}）"
    end
  end
end

