# 実行: bin/rails runner script/verify_hiragana_loop.rb
require "benchmark"

YOUON = %w[ゃ ゅ ょ].freeze

def count_mora_from_kana(text)
  chars = text.gsub(/[\s\u3000]/, '').chars
  chars.size - chars.count { |c| YOUON.include?(c) }
end

maeku  = "ちはやぶる神代も聞かず竜田川"
target = 14

def build_prompt(maeku, feedback: nil)
  base = <<~PROMPT
    あなたは連歌の宗匠です。以下の前句に対する付け句を作ってください。

    【出力の決まり】
    - ひらがなのみで14文字を出力する（漢字・カタカナ・句読点・記号・スペースは使わない）。
    - 14文字のひらがなのみを1行で出力する。
    - 例：ゆうぐれちかきかねのねひびく
    - 前句に出てくる言葉の読みは使わない（去嫌）。
    - 解説や前置きは書かず、ひらがなのみを出力する。

    【前句】
    #{maeku}
  PROMPT

  if feedback
    base += <<~FEEDBACK

      【やり直し】
      前回の答え「#{feedback[:ku]}」は#{feedback[:mora]}文字でした。
      14文字のひらがなで作り直してください。
    FEEDBACK
  end

  base + "\n付け句（ひらがな）："
end

feedback = nil
5.times do |i|
  prompt = build_prompt(maeku, feedback: feedback)
  result = nil
  elapsed = Benchmark.realtime { result = OllamaClient.generate(prompt, timeout: 60, think: false, temperature: 0.3) }
  ku = result.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
  mora = count_mora_from_kana(ku)

  puts "=== 試行#{i + 1}: #{elapsed.round(1)}秒 ==="
  puts "句: #{ku}"
  puts "文字数: #{ku.gsub(/[\s\u3000]/, '').size} / モーラ数: #{mora}（目標14）"

  if mora == target
    puts "→ OK!"
    break
  end
  feedback = { ku: ku, mora: mora }
end

