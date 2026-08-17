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

# 完結性チェック（T3・T6・T7改訂版）: LLMを介さない機械的判定。
# 判定はモデルの自己申告に頼らない（モデルは誤った結果にも自信満々に「✅」を付ける傾向が
# 一貫して観測されているため、Ruby側の機械的チェックに判定を一元化する）。
#
# T6改訂: 初版の「助詞終端の検出」では体言止め（助詞で終わらないが短い断片）を
# 検出できず、条件B/Cの全件が complete: true になり比較実験が機能しなかった。
# 体言止めは連歌の付句として正当な表現形式であり、終端の品詞では判定しない。
# 代わりに、担当パート（五音／七音）に紐づけた文字数下限のみで足切りする。
#
# T7改訂: T6の文字数閾値だけでは、prompt_redesign_v2_results.jsonl（T6改訂後の
# 再実行分）で観測された「山の露に秋風の音」等の断片を素通りさせてしまうことが
# 判明した。この断片群に共通するのは、プロンプトの「今回の情景の手がかり」
# （concrete_theme_phrase）に列挙した語句を、モデルがほぼそのまま出力に
# 転写しているだけで、独自の句として構成し直していない点である。
# そこで、テーマ語句のうち何割が出力に部分文字列としてそのまま含まれているかを
# 検出し、全語句が転写されている場合は「テーマ語句の丸ごと転写」として不完全と
# 判定する（自然な創作の結果テーマ語が1語だけ現れるのは許容し、全語一致のみを
# 検出条件とすることで誤検出を避ける）。
module CompletenessChecker
  # 担当パートごとの最低文字数（Rubyの String#length による機械的な文字数、
  # モデルへの自己申告要求は行わない）。五音・七音それぞれで現実的に
  # 成立しうる最短の文字数を暫定値として置く（例:「秋風」2文字で五音相当）。
  PART_LENGTH_THRESHOLDS = {
    five: 2,
    seven: 3
  }.freeze

  def self.part_key(part_label)
    part_label.to_s.include?('7音') ? :seven : :five
  end

  # concrete_theme_phrase（例:「山の露、秋風」）を「、」「,」区切りで語句に分解する。
  def self.theme_segments(concrete_theme_phrase)
    concrete_theme_phrase.to_s.split(/[、,]/).map(&:strip).reject(&:empty?)
  end

  # テーマの全語句が出力にそのまま部分文字列として含まれているかどうか。
  def self.theme_echo?(text, concrete_theme_phrase)
    segments = theme_segments(concrete_theme_phrase)
    return false if segments.empty?

    segments.all? { |segment| text.include?(segment) }
  end

  def self.check(output, part_label = '5音', concrete_theme_phrase = nil)
    text = output.to_s.strip
    return { complete: false, reason: :empty } if text.empty?

    threshold = PART_LENGTH_THRESHOLDS.fetch(part_key(part_label))
    return { complete: false, reason: :too_short_for_part } if text.length < threshold

    if concrete_theme_phrase && theme_echo?(text, concrete_theme_phrase)
      return { complete: false, reason: :theme_echo }
    end

    { complete: true, reason: nil }
  end
end

# 実験実行（T4・T5）
# T8: 前句・concrete_theme・出力先を差し替え可能にした（追試用）。
# デフォルト値はT4・T6・T7で使用した固定値のままとし、既存の実行結果との
# 再現性を壊さない。
class PromptRedesignV2Experiment
  DEFAULT_MAEKU = "玉なす月に鹿の声あり野辺の雪"
  DEFAULT_CONCRETE_THEME = "山の露、秋風"
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v2_results.jsonl', __FILE__)

  def initialize(maeku: DEFAULT_MAEKU, concrete_theme: DEFAULT_CONCRETE_THEME, output_path: DEFAULT_OUTPUT_PATH)
    @client = OllamaExperimentClient.new('qwen3:8b')
    @results = []
    @maeku = maeku
    @concrete_theme = concrete_theme
    @output_path = output_path
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
    maeku = @maeku
    persona = "世を捨てた庵の主として"
    concrete_theme = @concrete_theme
    part = "5音（第1句）"

    prompt = PromptTemplates.public_send(prompt_builder, maeku, persona, concrete_theme, part)
    # 実測: 平均310秒/句・最大800秒/句のため、既定値(180秒)では正常なケースでも
    # 打ち切られる。安全マージンを取り1200秒とする。
    output = @client.generate(prompt, temperature: 0.6, timeout: 1200)

    {
      condition: condition,
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      concrete_theme: concrete_theme,
      prompt_type: prompt_builder.to_s,
      output: output,
      completeness: CompletenessChecker.check(output, part, concrete_theme),
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
    path = @output_path
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
