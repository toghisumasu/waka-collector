#!/usr/bin/env ruby
# frozen_string_literal: true

# T10: 「モデルには自由に生成させ、Ruby側の抽出パーサーで句を後から取り出す」
# ハイブリッド設計のプロトタイプ検証（依頼書§10-6）
#
# 背景: T9で、B条件（映像化指示文＋【あなたの配役】ラベル＋情景の地の文化）の
# theme_echo抑制効果が、本番互換の「一行のみ・説明不要」出力制約下では消失する
# ことが判明した（§10-5）。§10-6の考察では、この「一行のみ・説明不要」という
# 制約自体がLLMの学習分布から外れた不自然な出力形式を強いる「強すぎる制約」で
# あり、theme_echo悪化の一因だという仮説を立てた。
#
# 本スクリプトは、(a)一行制約維持のまま別策を探る／(b)出力制約を緩和する、の
# 二択ではなく、(c)モデル呼び出し部分の出力制約は緩めたまま、句の切り出しを
# Ruby側の後処理に担わせる第三の設計を検証する。
#
# prompt_redesign_v3_scene_narrative.rb（T9）との差分:
# - 【出力】指示: 「一行だけ・説明不要」→「目標音数程度で、「」で囲んで示す。
#   前後に説明があってもよい」（B条件の出力指示に、目標音数の明示を追加）
# - 抽出: first_line → extract_verse（「」抽出＋前句引用除外＋first_lineフォールバック）
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v4_extract_verse.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v4_extract_verse_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

module PromptTemplates
  def self.build_scene_narrative_prompt_with_free_output(maeku, persona_description, scene_narrative, target_desc)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      #{target_desc}程度で、詠んだ句を「」で囲んで示してください。前後に説明や情景描写があっても構いません。
    PROMPT
  end
end

# T9で試作した「」抽出＋前句引用除外のロジックに、first_lineフォールバックを
# 追加したもの（§10-6の実装イメージにおけるextract_verse）。
# モデルが指示に反して「」を一切使わなかった場合の安全網として、
# 本番と同じfirst_line（最初の空行でない行）にフォールバックする。
module ExtractVerse
  def self.first_line(raw)
    raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
  end

  def self.call(raw, maeku)
    candidates = raw.to_s.scan(/「([^」]*)」/).flatten
    ku = candidates.reject { |c| c == maeku }.first
    ku || first_line(raw)
  end

  def self.theme_echo_words(ku, theme_keywords)
    return [] if ku.nil? || ku.empty?

    theme_keywords.select { |w| ku.include?(w) }
  end
end

class ExtractVerseExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v4_extract_verse_results.jsonl', __FILE__)

  def initialize(maeku: DEFAULT_MAEKU, persona: DEFAULT_PERSONA, scene_narrative: DEFAULT_SCENE_NARRATIVE,
                 theme_keywords: DEFAULT_THEME_KEYWORDS, output_path: DEFAULT_OUTPUT_PATH, attempts: 5)
    @client = OllamaExperimentClient.new('qwen3:8b')
    @results = []
    @maeku = maeku
    @persona = persona
    @scene_narrative = scene_narrative
    @theme_keywords = theme_keywords
    @output_path = output_path
    @attempts = attempts
  end

  def run
    puts "【T10: extract_verseハイブリッド設計の検証】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    target_desc = "七七（14音）" # 本番RengaGenerator#build_full_promptと同じ文言
    prompt = PromptTemplates.build_scene_narrative_prompt_with_free_output(@maeku, @persona, @scene_narrative, target_desc)
    output = @client.generate(prompt, temperature: 0.6, timeout: 1200)
    ku = ExtractVerse.call(output, @maeku)
    used_fallback = !output.to_s.include?("「#{ku}」")
    validation = KuValidator.new(ku, type: :tanku).validate # target_descが「七七（14音）」のため短句判定

    {
      attempt: attempt_no,
      maeku: @maeku,
      persona: @persona,
      scene_narrative: @scene_narrative,
      ku: ku,
      used_first_line_fallback: used_fallback,
      theme_echo_words: ExtractVerse.theme_echo_words(ku, @theme_keywords),
      mora: validation[:mora],
      mora_converged: validation[:result] == "ok",
      raw_response: output,
      timestamp: Time.now.iso8601(3)
    }
  rescue StandardError => e
    {
      attempt: attempt_no,
      maeku: @maeku,
      persona: @persona,
      scene_narrative: @scene_narrative,
      ku: nil,
      failure: e.message,
      timestamp: Time.now.iso8601(3)
    }
  end

  def save_results
    File.open(@output_path, 'w') do |f|
      @results.each { |result| f.puts(result.to_json) }
    end
    puts "\n✅ 結果を保存: #{@output_path}"
  end

  def print_summary
    completed = @results.count { |r| r[:ku] && !r[:ku].empty? }
    zero_match = @results.count { |r| r[:ku] && !r[:ku].empty? && r[:theme_echo_words].empty? }
    fallback_used = @results.count { |r| r[:used_first_line_fallback] }
    converged = @results.count { |r| r[:mora_converged] }
    puts "\n【結果サマリー】"
    puts "完走: #{completed}/#{@results.size}件"
    puts "theme_echo該当語ゼロ: #{zero_match}/#{completed}件"
    puts "first_lineフォールバック使用: #{fallback_used}/#{@results.size}件"
    puts "モーラ収束（14音一致）: #{converged}/#{completed}件"
  end
end

if __FILE__ == $0
  experiment = ExtractVerseExperiment.new
  experiment.run
end
