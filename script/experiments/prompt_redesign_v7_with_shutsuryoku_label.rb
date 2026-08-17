#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（再検証・差分検証2つ目）: v6に【出力】ラベルを追加した版（依頼書§10-8）
#
# 背景: v6（v5＋【音の目安】ラベル追加）はB条件相当の効果（theme_echo 0.2語程度）を
# 再現しなかった（有効4件でtheme_echo平均3.0語、モーラ収束0/4）。§10-4の記述
# 「【出力】を『前後に前句の説明や情景描写があっても構いません』に変更」から、
# B条件のプロンプトには【出力】という見出し付きの区画が存在した可能性がある。
# v3〜v6はこの見出しを持たず、出力指示を無見出しの地の文として配置していた。
#
# 本スクリプトはv6に対し、出力指示を【出力】ラベル付きの区画に変更する点のみを
# 差分とする。他の要素（persona・scene_narrative・【音の目安】の文言、抽出方式）は
# 変更しない。抽出バグ（前句部分引用・強調記法非対応、§10-8で発見）への対応は
# 本スクリプトのスコープに含めない（T11として別途起票済み）。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v7_with_shutsuryoku_label.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v7_with_shutsuryoku_label_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

module PromptTemplates
  def self.build_scene_narrative_prompt_with_shutsuryoku_label(maeku, persona_description, scene_narrative)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      【音の目安】
      前句の五七五とあなたの七七を目安として、音の流れを意識してください。

      【出力】
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

class WithShutsuryokuLabelExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v7_with_shutsuryoku_label_results.jsonl', __FILE__)

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
    puts "【T10再検証: 【出力】ラベル追加版】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    prompt = PromptTemplates.build_scene_narrative_prompt_with_shutsuryoku_label(@maeku, @persona, @scene_narrative)
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
  experiment = WithShutsuryokuLabelExperiment.new
  experiment.run
end
