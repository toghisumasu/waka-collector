# frozen_string_literal: true

class KuValidator
  CHOUKU = 17  # 長句（5-7-5）
  TANKU  = 14  # 短句（7-7）
  USER_DIC = Rails.root.join("dict", "user.dic").to_s


  def initialize(text, type: :chouku)
    @text = text
    @type = type
    @target = (type == :chouku) ? CHOUKU : TANKU
  end

  def validate
    return { result: "ng", mora: 0, message: "句が入力されていません" } unless valid_by_morphemes?

    mora = count_mora
    diff = (mora - @target).abs
    label = (@type == :chouku) ? "長句（17音）" : "短句（14音）"

    if mora == @target
      { result: "ok", mora: mora, message: nil }
    elsif diff == 1
      over = mora > @target ? "字余り" : "字足らず"
      { result: "warning", mora: mora, message: "#{label}として#{over}です（#{mora}音）。このまま続けますか？" }
    else
      { result: "ng", mora: mora, message: "#{label}に合致しません（#{mora}音）" }
    end
  end

  def count_mora
    require 'natto'
    nm = Natto::MeCab.new(userdic: USER_DIC)
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
    nm = Natto::MeCab.new(userdic: USER_DIC)
    clean = @text.gsub(/\s+/, '')

    return false if clean.empty?

    result = nm.parse(clean)
    morphemes = result.split("\n").reject { |line| line == "EOS" || line.empty? }

    morphemes.length >= 2
  end
end
