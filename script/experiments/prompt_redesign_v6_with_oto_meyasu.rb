#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（再検証・差分検証1つ目）: v5に【音の目安】ラベルを追加した版（依頼書§10-8・D-T10-1相談）
#
# 背景: v4（目標モーラ数を出力指示末尾に明示）・v5（音数指示を完全除去）とも
# theme_echo抑制率・モーラ収束率・目視評価のいずれもB条件（10-3・10-4、0.2語・
# zero-match 4/5）に届かず、負の結果だった。B条件のアドホック実行時のプロンプト
# 原文は保存されておらず(D-T10-1追加の背景)、依頼書の記述から再構成するしかない。
#
# 依頼書§10-4「トップ指示文除去版」の差分説明に「【音の目安】に『前句の五七五と
# あなたの七七を』を追加」とある。これは、B条件のプロンプトに【音の目安】という
# 項目が存在していた可能性を示す一次的な手がかりである。v3〜v5にはこの項目が
# 一切存在しないため、本スクリプトはv5（音数指示なし版）に【音の目安】ラベルの
# 追加のみを行い、他の要素（persona・scene_narrativeの文言、抽出方式）は変更しない。
#
# 【音の目安】の内容は§10-4の文言「前句の五七五とあなたの七七を」を土台に、
# 依頼書に記録されている範囲で妥当な形に復元した推測文であり、原文そのものでは
# ない（原文が失われているため）。この推測が的を外している可能性は残る。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v6_with_oto_meyasu.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v6_with_oto_meyasu_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

module PromptTemplates
  def self.build_scene_narrative_prompt_with_oto_meyasu(maeku, persona_description, scene_narrative)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      【音の目安】
      前句の五七五とあなたの七七を目安として、音の流れを意識してください。

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

class WithOtoMeyasuExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v6_with_oto_meyasu_results.jsonl', __FILE__)

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
    puts "【T10再検証: 【音の目安】ラベル追加版】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    prompt = PromptTemplates.build_scene_narrative_prompt_with_oto_meyasu(@maeku, @persona, @scene_narrative)
    output = @client.generate(prompt, temperature: 0.6, timeout: 1200)
    ku = ExtractVerse.call(output, @maeku)
    used_fallback = !output.to_s.include?("「#{ku}」")
    validation = KuValidator.new(ku, type: :tanku).validate

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
  experiment = WithOtoMeyasuExperiment.new
  experiment.run
end
