# 連歌の付合の一致率(%)。
# 類似度 = 部立+季の集合のJaccard。較正の根拠は Project の renga_match_rate_calibration.md。
#   類似度0 → 20% / 0.5 → 80% / 1.0 → 90%(集合だけの一致の上限)
#   本文がほぼ同じ(オウム返し) → 100% / 本文が空 → 0%
#   式目違反のある付合は 0〜19% の領域(違反が多いほど低い)
require "set"

class RengaMatchScore
  R_NEAR          = 0.5    # 式目を満たす最も近い付合の類似度(暫定、湯山の90%点)
  SET_MAX         = 90.0   # 集合の一致だけで届く上限
  ECHO_THRESHOLD  = 0.8    # 本文の文字bigramのJaccardがこれ以上ならオウム返し
  VIOLATION_CEIL  = 19.0   # 違反ありの付合の上限(%)
  VIOLATION_STEP  = 3.0    # 違反が2件目以降、1件ごとに引く点数
  SEASONS = %w[春 夏 秋 冬].freeze

  # prev, nxt: { text:, bui:, season: }(類似度の集合に match_bui があればそちらを使う)
  def self.call(prev, nxt, violations: 0)
    return 0.0 if blank?(prev) || blank?(nxt)
    base = echo?(prev, nxt) ? 100.0 : score(similarity(prev, nxt))
    apply_violations(base, violations)
  end

  # verses: 作品の句の配列。checker を渡すと、違反を各付合の付句に割り当てる。
  # 戻り値: 付合ごとの一致率(長さ verses.size - 1)。
  def self.score_chain(verses, checker: nil)
    counts = Hash.new(0)
    checker&.scan_chain(verses)&.each { |v| counts[v[:pos]] += 1 }
    verses.each_cons(2).with_index.map do |(a, b), k|
      call(a, b, violations: counts[k + 2])   # 付句は 1始まりで k+2 番目
    end
  end

  def self.similarity(a, b)
    x = tags(a)
    y = tags(b)
    return 0.0 if x.empty? && y.empty?
    (x & y).size.to_f / (x | y).size
  end

  def self.score(r)
    return 20.0 + 60.0 * r / R_NEAR if r <= R_NEAR
    80.0 + (SET_MAX - 80.0) * (r - R_NEAR) / (1.0 - R_NEAR)
  end

  def self.apply_violations(base, n)
    return base if n.to_i <= 0
    [base * VIOLATION_CEIL / 100.0 - VIOLATION_STEP * (n - 1), 0.0].max
  end

  def self.echo?(a, b)
    x = bigrams(a[:text])
    y = bigrams(b[:text])
    return false if x.empty? || y.empty?
    (x & y).size.to_f / (x | y).size >= ECHO_THRESHOLD
  end

  def self.bigrams(text)
    t = text.to_s.gsub(/[\s　、。,.・]/, "")
    return Set.new(t.chars) if t.size < 2
    Set.new(t.each_char.each_cons(2).map(&:join))
  end

  def self.tags(v)
    Array(v[:match_bui] || v[:bui]) + (SEASONS.include?(v[:season]) ? [v[:season]] : [])
  end

  def self.blank?(v)
    v[:text].to_s.strip.empty?
  end
  private_class_method :tags, :blank?, :bigrams, :echo?, :apply_violations
end
