#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（再検証）: extract_verseハイブリッド設計から目標モーラ数の明示を除いた版
# （依頼書§10-8）
#
# 背景: prompt_redesign_v4_extract_verse.rb（目標モーラ数「七七（14音）程度で」を
# 明示した版）は、theme_echo抑制率0/5・モーラ収束率1/5・目視評価1/5成立と、
# B条件（10-3・10-4）を全評価軸で下回る負の結果になった（§10-8）。
# B条件は出力指示に音数への言及を含んでいなかった点がv4との主な差分であるため、
# 本スクリプトは目標モーラ数の明示を出力指示から完全に除去し、B条件の出力指示
# （「詠んだ句を「」で囲んで示してください。前後に説明や情景描写があっても
# 構いません。」）をそのまま用いる。抽出方式（extract_verse、「」抽出＋
# 前句引用除外＋first_lineフォールバック）はv4から変更しない。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v5_extract_verse_no_mora.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v5_extract_verse_no_mora_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

module PromptTemplates
  def self.build_scene_narrative_prompt_no_mora(maeku, persona_description, scene_narrative)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      詠んだ句を「」で囲んで示してください。前後に説明や情景描写があっても構いません。
    PROMPT
  end
end

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

class ExtractVerseNoMoraExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v5_extract_verse_no_mora_results.jsonl', __FILE__)

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
    puts "【T10再検証: extract_verseハイブリッド設計・音数指示なし】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    prompt = PromptTemplates.build_scene_narrative_prompt_no_mora(@maeku, @persona, @scene_narrative)
    output = @client.generate(prompt, temperature: 0.6, timeout: 1200)
    ku = ExtractVerse.call(output, @maeku)
    used_fallback = !output.to_s.include?("「#{ku}」")
    validation = KuValidator.new(ku, type: :tanku).validate # 前句が長句のため短句判定を基準に測定（本設計では出力指示に音数を明示しない）

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
  experiment = ExtractVerseNoMoraExperiment.new
  experiment.run
end
