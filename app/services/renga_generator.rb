# frozen_string_literal: true

class RengaGenerator
  VERSE_FORMATS = {
    chouku: { label: "五七五", mora_desc: "五音＋七音＋五音（合わせて17音）",
              example: "「山深く 紅葉色づく 秋の風」（5+7+5音）" },
    tanku:  { label: "七七",   mora_desc: "七音＋七音（合わせて14音）",
              example: "「静けさ残り 夜空に星が光る」（7+7音）" }
  }.freeze

  def initialize(maeku, honka_candidates = [], verse_type = :tanku)
    @maeku            = maeku
    @honka_candidates = honka_candidates
    @verse_type       = verse_type
  end

  def generate_tsugeku
    raw = OllamaClient.generate(build_prompt)
    raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
  end

  private

  def build_prompt
    format = VERSE_FORMATS.fetch(@verse_type, VERSE_FORMATS[:tanku])
    honka_text = @honka_candidates.map { |w| "・#{w.upper_phrase_text}#{w.lower_phrase_text}（#{w.author}）" }.join("\n")

    prompt = <<~PROMPT
      あなたは連歌の宗匠です。前句に対する#{format[:label]}の付け句を作ってください。

      【出力の決まり】
      - 付け句を1行だけ出力する（改行なし）。
      - 必ず#{format[:label]}（#{format[:mora_desc]}）の形式にする。
      - 例：#{format[:example]}
      - 前句に出てくる言葉は使わない（去嫌）。
      - 解説や前置きは一切書かず、付け句本体のみを出力する。

      【前句】
      #{@maeku}

    PROMPT

    if honka_text.present?
      prompt += <<~HONKA
        【本歌参照候補（活用は任意）】
        #{honka_text}

      HONKA
    end

    prompt += "付け句："
    prompt
  end
end

