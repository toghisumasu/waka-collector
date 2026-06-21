# 実行: bin/rails runner script/verify_hiragana_generation.rb
require "benchmark"

YOUON = %w[ゃ ゅ ょ].freeze

def count_mora_from_kana(text)
  chars = text.gsub(/[\s\u3000]/, '').chars
  chars.size - chars.count { |c| YOUON.include?(c) }
end

maeku = "ちはやぶる神代も聞かず竜田川"

prompt = <<~PROMPT
  あなたは連歌の宗匠です。以下の前句に対する七七の付け句を作ってください。

  【出力の決まり】
  - ひらがなのみで1行出力する（漢字・カタカナ・句読点・記号は使わない）。
  - 必ず七音＋七音（合わせて14音）にする。
  - 例：ゆうぐれちかき かねのねひびく
  - 前句に出てくる言葉の読みは使わない（去嫌）。
  - 解説や前置きは書かず、付け句のひらがなのみを出力する。

  【前句】
  #{maeku}

  付け句（ひらがな）：
PROMPT

result = nil
elapsed = Benchmark.realtime do
  result = OllamaClient.generate(prompt)
end

raw_line = result.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
mora = count_mora_from_kana(raw_line)

puts "=== 生成結果（ひらがな） ==="
puts raw_line
puts "=== モーラ数: #{mora} ==="
puts "=== 所要時間: #{elapsed.round(1)}秒 ==="

