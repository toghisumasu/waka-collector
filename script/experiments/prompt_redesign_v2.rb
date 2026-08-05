#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1: 付句生成プロンプト再設計（形式面の拘束＋完結性チェック）
# 実験スクリプト（独立動作、本番RengaGenerator/StepwiseWakaGenerator非変更）
#
# 背景: Phase 0（prompt_redesign_v1.rb）で「音数不一致時にモデルが断片で妥協終了する」
# 失敗パターンが判明した。本実験では、数値の下限を課さず「完結した句として出力せよ」
# という形式面の拘束のみをプロンプトに追加し（条件C）、拘束なしの条件Bと比較する。
# 完結性の判定はモデルの自己申告に頼らず、Ruby側の機械的チェック（CompletenessChecker）で行う。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v2.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v2_results.jsonl （10行: 条件B5件+条件C5件）

# OllamaExperimentClient・PromptTemplates・PROJECT_ROOT・Rails環境ロードをv1から再利用する。
# require_relativeはv1の`if __FILE__ == $0`ガードにより実験本体を実行しない。
require_relative 'prompt_redesign_v1'

# 条件C用プロンプト（T2）: 条件Bに「完結した句として出力せよ」という形式面の拘束のみを追加。
# 数値（「最低◯音」等）・自己検証を促す語句（「確認しろ」「数えろ」等）は一切含めない。
# 既存の音数指示（「目安として」の一文）は変更しない。
module PromptTemplates
  def self.build_new_prompt_with_completion_constraint(maeku, persona_description, concrete_theme_phrase, part)
    <<~PROMPT
      【前句】
      #{maeku}
      （この前句の文言は変更せず、そのまま次の句に引き継いでください）

      【視点】
      #{persona_description}

      【今回の情景の手がかり】
      #{concrete_theme_phrase}

      【音の目安】
      57577の調べのうち、あなたが担当するのは #{part} の部分です。目安として音の流れを意識してください（細かな過不足は後で整えます）。

      【出力】
      新しい句のみを一行で示してください。説明・解説・音数の確認は不要です。
      途中の断片で終わらせず、必ず一つの完結した句として出力してください。
    PROMPT
  end
end

# 完結性チェック（T3）: LLMを介さない機械的判定。
# Phase 0で観測された失敗（断片のまま出力終了）を検出する。
# 判定はモデルの自己申告に頼らない（モデルは誤った結果にも自信満々に「✅」を付ける傾向が
# 一貫して観測されているため、Ruby側の機械的チェックに判定を一元化する）。
module CompletenessChecker
  # Phase 0で観測された断片出力は5〜10文字程度だった（例:「山の露秋風」5文字）。
  # ここでは閾値を厳しくしすぎて正当な短い句を誤検出するリスクを避けるため、
  # 明確に異常な極端な短さ（1文字以下）のみを検出する暫定値とする。
  SHORT_LENGTH_THRESHOLD = 2

  # 「に」「て」「で」「が」「を」「の」「と」で終わる場合、接続助詞・格助詞で文が途切れ、
  # 後続が省略されたまま出力が終わっている可能性が高いと判断する簡易ルール。
  INCOMPLETE_ENDING_PARTICLES = %w[に て で が を の と].freeze

  def self.check(output)
    text = output.to_s.strip
    return { complete: false, reason: :empty } if text.empty?
    return { complete: false, reason: :too_short } if text.length < SHORT_LENGTH_THRESHOLD
    if INCOMPLETE_ENDING_PARTICLES.any? { |particle| text.end_with?(particle) }
      return { complete: false, reason: :ends_with_particle }
    end

    { complete: true, reason: nil }
  end
end

# 実験実行（T4・T5）
class PromptRedesignV2Experiment
  def initialize
    @client = OllamaExperimentClient.new('qwen3:8b')
    @results = []
  end

  def run
    puts "【Phase 1: 形式面の拘束＋完結性チェック】"
    puts "条件B（Phase 0既存・拘束なし）5回実行..."
    run_condition_b
    puts "条件C（本タスク・完結性拘束あり）5回実行..."
    run_condition_c
    save_results
    print_summary
  end

  private

  def run_condition_b
    5.times do |i|
      result = generate(condition: 'B', attempt_no: i + 1, prompt_builder: :build_new_prompt)
      @results << result
      puts "  B-#{i + 1}: #{result[:output][0..20]}..." if result[:output]
    end
  end

  def run_condition_c
    5.times do |i|
      result = generate(condition: 'C', attempt_no: i + 1, prompt_builder: :build_new_prompt_with_completion_constraint)
      @results << result
      puts "  C-#{i + 1}: #{result[:output][0..20]}..." if result[:output]
    end
  end

  def generate(condition:, attempt_no:, prompt_builder:)
    maeku = PromptTemplates.sample_maeku
    persona = "世を捨てた庵の主として"
    concrete_theme = "山の露、秋風"
    part = "5音（第1句）"

    prompt = PromptTemplates.public_send(prompt_builder, maeku, persona, concrete_theme, part)
    output = @client.generate(prompt, temperature: 0.6)

    {
      condition: condition,
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      concrete_theme: concrete_theme,
      prompt_type: prompt_builder.to_s,
      output: output,
      completeness: CompletenessChecker.check(output),
      timestamp: Time.now.iso8601(3)
    }
  rescue StandardError => e
    {
      condition: condition,
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      concrete_theme: concrete_theme,
      prompt_type: prompt_builder.to_s,
      output: nil,
      failure: e.message,
      timestamp: Time.now.iso8601(3)
    }
  end

  def save_results
    path = File.expand_path('../../../tmp/experiments/prompt_redesign_v2_results.jsonl', __FILE__)
    File.open(path, 'w') do |f|
      @results.each do |result|
        if result[:output]
          result[:char_count] = result[:output].length
          validator = KuValidator.new(result[:output])
          result[:mora_count] = validator.count_mora
          result[:verse_type] = KuValidator.nearest_verse_type(result[:mora_count])
        end
        f.puts(result.to_json)
      end
    end
    puts "\n✅ 結果を保存: #{path}"
  end

  def print_summary
    puts "\n【結果サマリー】"
    puts "B条件（拘束なし）: #{@results.count { |r| r[:condition] == 'B' && r[:output] }}件完走"
    puts "C条件（拘束あり）: #{@results.count { |r| r[:condition] == 'C' && r[:output] }}件完走"
    b_ng = @results.count { |r| r[:condition] == 'B' && r[:completeness] && !r[:completeness][:complete] }
    c_ng = @results.count { |r| r[:condition] == 'C' && r[:completeness] && !r[:completeness][:complete] }
    puts "完結性チェックNG（B）: #{b_ng}件"
    puts "完結性チェックNG（C）: #{c_ng}件"
  end
end

if __FILE__ == $0
  experiment = PromptRedesignV2Experiment.new
  experiment.run
end
