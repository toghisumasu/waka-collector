# frozen_string_literal: true

# UniDic和歌版（CC BY-NC-SA 4.0、非営利限定）を用いた形態素解析の並行運用サービス。
# ku_validator.rb（IPA辞書ベースのモーラ判定）とは独立しており、双方に影響を与えない。
# 辞書本体はリポジトリに同梱せず、環境変数WAKA_UNIDIC_DICDIRで参照する（其の六十九）。
class WakaUnidicAnalyzer
  class UnavailableError < StandardError; end
  class UnsupportedFeatureFormatError < StandardError; end

  Morpheme = Struct.new(:surface, :pos, :lform, :lemma, :pron, :pron_base, keyword_init: true)

  # 列位置はdocs/phase0_unidic_koshabun_report.mdの実測、および
  # UniDic和歌版 tmp/unidic-waka での実測（其の六十九）に基づく。
  # 想定外の列数を持つビルドを読み込んだ場合はKeyErrorではなく明示的な例外を出す。
  FEATURE_LAYOUTS = {
    29 => { pos: 0, lform: 6, lemma: 7, pron: 9, pron_base: 11 }
  }.freeze

  def self.available?
    ENV["WAKA_UNIDIC_DICDIR"].present?
  end

  def self.instance
    return nil unless available?

    @instance ||= new
  end

  def initialize
    dicdir = ENV["WAKA_UNIDIC_DICDIR"]
    raise UnavailableError, "WAKA_UNIDIC_DICDIR is not set" if dicdir.blank?

    args = ["-d", dicdir]
    userdic = ENV["WAKA_UNIDIC_USERDIC"]
    args += ["-u", userdic] if userdic.present?

    @mecab = Natto::MeCab.new(args.join(" "))
  end

  def analyze(text)
    return [] if text.blank?

    clean = text.gsub(/\s+/, "")
    morphemes = []
    @mecab.parse(clean) do |node|
      next if node.is_eos?

      morphemes << build_morpheme(node)
    end
    morphemes
  end

  private

  def build_morpheme(node)
    features = node.feature.split(",")
    layout = FEATURE_LAYOUTS[features.size]
    unless layout
      raise UnsupportedFeatureFormatError,
            "unexpected UniDic feature column count: #{features.size} (surface=#{node.surface})"
    end

    Morpheme.new(
      surface: node.surface,
      pos: features[layout[:pos]],
      lform: features[layout[:lform]],
      lemma: features[layout[:lemma]],
      pron: features[layout[:pron]],
      pron_base: features[layout[:pron_base]]
    )
  end
end
