# 連歌の付合の一致率(%)。類似度は部立+季の集合のJaccard。
# 較正の根拠は docs ではなく Project の renga_match_rate_calibration.md を参照。
class RengaMatchScore
  R_NEAR = 0.5   # 式目を満たす最も近い付合の類似度(暫定、湯山の90%点)
  SEASONS = %w[春 夏 秋 冬].freeze

  # verse: { text:, bui: [..], season: "春" など }
  def self.call(prev, nxt)
    return 0.0 if blank?(prev) || blank?(nxt)
    score(similarity(prev, nxt))
  end

  def self.similarity(a, b)
    x = tags(a)
    y = tags(b)
    return 0.0 if x.empty? && y.empty?
    (x & y).size.to_f / (x | y).size
  end

  def self.score(r)
    return 20.0 + 60.0 * r / R_NEAR if r <= R_NEAR
    80.0 + 20.0 * (r - R_NEAR) / (1.0 - R_NEAR)
  end

  def self.tags(v)
    Array(v[:bui]) + (SEASONS.include?(v[:season]) ? [v[:season]] : [])
  end

  def self.blank?(v)
    v[:text].to_s.strip.empty?
  end
  private_class_method :tags, :blank?
end
