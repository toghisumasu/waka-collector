#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（再検証・新規検証）: 【音の目安】を"○"記号でモーラ数を視覚的に明示する版
# （依頼書§10-8の続き。ユーザー提示のプロンプト案、2026-08-17）
#
# 背景: v6（【音の目安】をテキストで「前句の五七五とあなたの七七を目安として」と
# 表現）・v7（v6+【出力】ラベル）はいずれもB条件（0.2語・zero-match 4/5）を
# 再現せず、v9（temperatureキー省略）も再現しなかった（本節参照）。ラベル構造・
# 実行時パラメータ双方が負の結果に終わったのを受け、ユーザーから新しいプロンプト案
# （音の目安を"○"記号でモーラ数として明示するテンプレート）が提示された。
#
# 懸念点（ユーザー指摘）: "○"記号による具体的な数の可視化は、過去に観測された
# 「モーラを数えさせる指示が捏造を誘発する」パターンに近い可能性がある。本実験では
# theme_echo・モーラ収束率に加え、raw_response内の不自然な文字反復や、
# "○"の数に無理に文字数を合わせようとした形跡がないか目視確認する
# （print_summaryでは自動判定できないため、実行後に人間が生ログを確認する）。
#
# プロンプト文面はv6/v9（B条件の再構成、persona・scene_narrative・「」抽出方式）
# と同一で、【音の目安】部分のみユーザー指定のverbatim文言に差し替えている。
# D-T10-1に従い、当該文面全文を script/experiments/prompts/v10_mora_marker_prompt.txt
# として保存済み（本ファイルのPROMPT定数もそれと完全一致させること）。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v10_mora_marker.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v10_mora_marker_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

module PromptTemplates
  def self.build_scene_narrative_prompt_with_mora_marker(maeku, persona_description, scene_narrative)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      【音の目安】前句の読み仮名で五七五（○○○○○　○○○○○○○　○○○○○）とあなたの七七（○○○○○○○　○○○○○○○）を"○"の数を読み仮名の目安として、音の流れを意識してください。

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

  # 目視確認の補助: raw_response内に"○"文字自体が混入していないか、
  # 極端な文字反復（同一文字が5回以上連続）がないかを機械的に検出する。
  # これは目視確認の代替ではなく、目視すべき箇所を絞り込むための補助フラグ。
  def self.suspicious_patterns(raw)
    flags = []
    flags << :maru_leaked_into_output if raw.to_s.include?('○')
    flags << :repeated_char if raw.to_s =~ /(.)\1{4,}/
    flags
  end
end

class MoraMarkerExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v10_mora_marker_results.jsonl', __FILE__)

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
    puts '【T10: 【音の目安】"○"記号によるモーラ数明示版】'
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    prompt = PromptTemplates.build_scene_narrative_prompt_with_mora_marker(@maeku, @persona, @scene_narrative)
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
      suspicious_patterns: ExtractVerse.suspicious_patterns(output),
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
    suspicious = @results.count { |r| r[:suspicious_patterns] && !r[:suspicious_patterns].empty? }
    puts "\n【結果サマリー】"
    puts "完走: #{completed}/#{@results.size}件"
    puts "theme_echo該当語ゼロ: #{zero_match}/#{completed}件"
    puts "first_lineフォールバック使用: #{fallback_used}/#{@results.size}件"
    puts "モーラ収束（14音一致）: #{converged}/#{completed}件"
    puts "機械的な不審パターン検出（要目視確認）: #{suspicious}/#{@results.size}件"
  end
end

if __FILE__ == $0
  experiment = MoraMarkerExperiment.new
  experiment.run
end
