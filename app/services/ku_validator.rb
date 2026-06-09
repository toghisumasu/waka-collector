# frozen_string_literal: true

class KuValidator
  def initialize(text)
    @text = text
  end

  def valid?
    valid_by_morphemes?
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
end# frozen_string_literal: true

class KuValidator
  def initialize(text)
    @text = text
  end

  def valid?
    valid_by_morphemes?
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
