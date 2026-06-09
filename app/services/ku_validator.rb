# frozen_string_literal: true

class KuValidator
  CHOUKU = 17  # 長句（5-7-5）
  TANKU  = 14  # 短句（7-7）

  def initialize(text)
    @text = text
  end

  def validate
    return { result: "ng", mora: 0, message: "句が入力されていません" } unless valid_by_morphemes?

    mora = count_mora

    if mora == CHOUKU || mora == TANKU
      { result: "ok", mora: mora, message: nil }
    elsif (mora - CHOUKU).abs <= 1 || (mora - TANKU).abs <= 1
      type = (mora - CHOUKU).abs <= 1 ? "長句" : "短句"
      { result: "warning", mora: mora, message: "#{type}として字#{mora > CHOUKU || mora > TANKU ? '余り' : '足らず'}です（#{mora}音）。このまま続けますか？" }
    else
      { result: "ng", mora: mora, message: "長句（17音）にも短句（14音）にも合致しません（#{mora}音）" }
    end
  end

  def count_mora
    require 'natto'
    nm = Natto::MeCab.new
    clean = @text.gsub(/\s+/, '')

    yomi_parts = []
    nm.parse(clean) do |node|
      next if node.is_eos?
      features = node.feature.split(",")
      yomi_parts << (features[7] || node.surface)
    end

    yomi_str = yomi_parts.join("")
    hiragana = yomi_str.tr('ァ-ヴー', 'ぁ-ゔー')
    hiragana.gsub(/[ゃゅょ]/, '').length
  end

  private

  def valid_by_morphemes?
    require 'natto'
    nm = Natto::MeCab.new
    clean = @text.gsub(/\s+/, '')

    return false if clean.empty?

    result = nm.parse(clean)
    morphemes = result.split("\n").reject { |line| line == "EOS" || line.empty? }

    morphemes.length >= 2
  end
end
