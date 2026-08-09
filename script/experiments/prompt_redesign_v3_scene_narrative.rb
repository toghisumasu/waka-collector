#!/usr/bin/env ruby
# frozen_string_literal: true

# T9: B条件（情景の物語的記述＋【あなたの配役】ラベル、§10-4で確定）の資産化
#
# 背景: 依頼書§10-1(b)の追試（/tmp上のアドホックなOllama直接呼び出し）で、
# テーマを名詞列挙（例:「山の露、秋風」）ではなく物語的な情景描写文にし、
# あわせてプロンプトの項目立てを【視点】【情景】から【あなたの配役】＋地の文へ
# 変更したところ、theme_echo（情景描写語のそのままの転写）が大幅に減少した
# （§10-3・10-4のB条件、6語中平均0.2語・5回中4回がゼロ）。
# 本スクリプトはこの構成を再利用可能なメソッドとして固定化する。
#
# 改訂（本番方式との整合）: 初版は【出力】を「詠んだ句を「」で囲んで示す」
# 形式（前後の説明・情景描写を許容）としていたが、本番（RengaGenerator・
# StepwiseWakaGenerator、いずれもVerseTextAnalysis#first_line経由）は
# 一貫して「〜を一行だけ出力してください。説明や前置きは不要です。」と
# 指示し、出力の最初の空行でない行をそのまま句として採用する方式である。
# 説明文を句の前後に置くことを許容する設計は本番には存在しないため、
# 初版の【出力】指示は本番の抽出方式（first_line）と噛み合わない。
# 本改訂では、B条件の核（映像化指示文＋【あなたの配役】ラベル＋情景の
# 地の文化）は維持したまま、【出力】指示のみを本番と同じ「一行だけ・
# 説明不要」形式に変更し、抽出も「」ベースではなくfirst_line方式に
# 差し替えて、theme_echo抑制効果が本番互換の出力制約下でも残るかを見る。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v3_scene_narrative.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v3_scene_narrative_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

# B条件のプロンプト構成（§10-4で確定、出力指示のみ本番方式に改訂）:
# - トップに「以下の前句が表す映像に続く句を詠んでください。」という指示文を置く
# - 【前句】【あなたの配役】ラベルは維持する
# - 【情景】ラベルは使わず、情景描写文を配役に続く地の文として配置する
# - 出力指示は本番のbuild_full_prompt末尾と同じ
#   「#{target_desc}を一行だけ出力してください。説明や前置きは不要です。」
module PromptTemplates
  def self.build_scene_narrative_prompt(maeku, persona_description, scene_narrative, target_desc)
    <<~PROMPT
      以下の前句が表す映像に続く句を詠んでください。

      【前句】
      #{maeku}

      【あなたの配役】
      #{persona_description}

      #{scene_narrative}

      #{target_desc}を一行だけ出力してください。説明や前置きは不要です。
    PROMPT
  end
end

# B条件専用のtheme_echo判定。抽出そのものは本番のVerseTextAnalysis#first_line
# と同じロジック（最初の空行でない行を採用）をそのままこのモジュールに
# 持たせる（app/配下は変更せず、script/experiments/内で同等の実装を用いる）。
module SceneNarrativeExtractor
  def self.first_line(raw)
    raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
  end

  # theme_keywordsのうち、抽出句に部分文字列として含まれる語を返す
  # （§10-3・10-4のtheme_echo集計と同じ定義：情景描写文由来の名詞語彙）。
  def self.theme_echo_words(ku, theme_keywords)
    return [] if ku.nil? || ku.empty?

    theme_keywords.select { |w| ku.include?(w) }
  end
end

# T9実行クラス。PromptRedesignV2Experimentとは出力形式（「」抽出）が異なるため
# 個別のクラスとして定義する。既存のOllamaExperimentClientをそのまま再利用する。
class SceneNarrativeExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v3_scene_narrative_results.jsonl', __FILE__)

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
    puts "【T9: B条件（情景の物語的記述）の資産化検証】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    target_desc = "七七（14音）" # 本番RengaGenerator#build_full_promptと同じ文言
    prompt = PromptTemplates.build_scene_narrative_prompt(@maeku, @persona, @scene_narrative, target_desc)
    output = @client.generate(prompt, temperature: 0.6, timeout: 1200)
    ku = SceneNarrativeExtractor.first_line(output)

    {
      attempt: attempt_no,
      maeku: @maeku,
      persona: @persona,
      scene_narrative: @scene_narrative,
      ku: ku,
      theme_echo_words: SceneNarrativeExtractor.theme_echo_words(ku, @theme_keywords),
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
    puts "\n【結果サマリー】"
    puts "完走: #{completed}/#{@results.size}件"
    puts "theme_echo該当語ゼロ: #{zero_match}/#{completed}件"
  end
end

if __FILE__ == $0
  experiment = SceneNarrativeExperiment.new
  experiment.run
end
