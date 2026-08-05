#!/usr/bin/env ruby
# frozen_string_literal: true

# 其の七十五 Phase 0: 付句生成プロンプト再設計
# 実験スクリプト（独立動作、本番RengaGenerator非変更）
#
# 背景: 2026-07-31〜08-02の手動実験で得た知見を基に、新しいプロンプト構成案を
# 既存本番コード変更なしで検証する。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v1.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v1_results.jsonl （10行: 条件A5件+条件B5件）

require 'net/http'
require 'uri'
require 'json'
require 'time'

# プロジェクトルートを確定（__FILE__がscript/experiments/prompt_redesign_v1.rbなので3段上）
PROJECT_ROOT = File.expand_path('../../../', __FILE__)

# Rails環境を最小限ロード（KuValidator用）
ENV['RAILS_ENV'] ||= 'test'
require File.join(PROJECT_ROOT, 'config', 'environment')

# Ollama APIクライアント（スタンドアロン）
class OllamaExperimentClient
  DEFAULT_ENDPOINT = 'http://localhost:11434/api/generate'

  def initialize(model = 'qwen3:8b', endpoint = DEFAULT_ENDPOINT)
    @model = model
    @endpoint = endpoint
  end

  def generate(prompt, timeout: 180, temperature: 0.6)
    uri = URI(@endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = timeout
    http.write_timeout = timeout

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'

    payload = {
      model: @model,
      prompt: prompt,
      temperature: temperature,
      stream: false
    }
    request.body = payload.to_json

    response = http.request(request)
    raise "Ollama error: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    result = JSON.parse(response.body)
    result['response'].strip
  rescue StandardError => e
    raise "Ollama request failed: #{e.message}"
  end
end

# プロンプト構築（T2で拡張）
module PromptTemplates
  # 前句の例
  def self.sample_maeku
    "玉なす月に鹿の声あり野辺の雪"
  end

  # 新プロンプト（条件B: abstract方式）
  def self.build_new_prompt(maeku, persona_description, concrete_theme_phrase, part)
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
    PROMPT
  end

  # 旧プロンプト（条件A: 既存RengaGenerator相当、簡略版）
  def self.build_old_prompt(maeku, persona_description, theme_words, part)
    <<~PROMPT
      前句：#{maeku}

      視点：#{persona_description}
      テーマ：#{theme_words}

      31音の短歌構成（57577）の中で、#{part}を作成してください。
      正確な音数（5音または7音）で新しい句を一行で示してください。
      説明や音数検証は不要です。
    PROMPT
  end
end

# 前句保持チェック
# 前句という素材そのものが生成過程で改変・重複・欠落していないかを検証する。
# 前句の語彙を付句が再利用すべきという想定は誤りのため、部分一致・閾値方式は採らない。
#
# 注意: 本実験（prompt_redesign_v1）は付句のみを出力させる構成のため、
# outputに前句が登場することはなく、このチェックは常にfalseとなる（N/A、対象外）。
# 前句をプロンプト経由で出力側に含める設計（StepwiseWakaGeneratorの中間ステップ等）を
# 検証する際に、前句の改変・重複・欠落の検出用として転用することを想定して残している。
def check_maeku_preservation(output, maeku)
  return false if output.nil?

  normalize = ->(text) { text.gsub(/\s+/, '') }
  normalize.call(output).include?(normalize.call(maeku))
end

# 実験実行
class PromptRedesignExperiment
  def initialize
    @client = OllamaExperimentClient.new('qwen3:8b')
    @results = []
  end

  def run
    puts "【Phase 0: 付句生成プロンプト再設計】"
    puts "条件A（旧型）5回実行..."
    run_condition_a
    puts "条件B（新型）5回実行..."
    run_condition_b
    save_results
    print_summary
  end

  private

  def run_condition_a
    5.times do |i|
      result = generate_with_old_prompt(i + 1)
      @results << result
      puts "  A-#{i + 1}: #{result[:output][0..20]}..." if result[:output]
    end
  end

  def run_condition_b
    5.times do |i|
      result = generate_with_new_prompt(i + 1)
      @results << result
      puts "  B-#{i + 1}: #{result[:output][0..20]}..." if result[:output]
    end
  end

  def generate_with_old_prompt(attempt_no)
    maeku = PromptTemplates.sample_maeku
    persona = "世を捨てた庵の主として"
    theme = "山の露、秋風"
    part = "5音（第1句）"

    prompt = PromptTemplates.build_old_prompt(maeku, persona, theme, part)
    output = @client.generate(prompt, temperature: 0.6)

    {
      condition: 'A',
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      theme: theme,
      prompt_type: 'old',
      output: output,
      maeku_preserved: check_maeku_preservation(output, maeku),
      timestamp: Time.now.iso8601(3)
    }
  rescue StandardError => e
    {
      condition: 'A',
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      theme: theme,
      prompt_type: 'old',
      output: nil,
      failure: e.message,
      timestamp: Time.now.iso8601(3)
    }
  end

  def generate_with_new_prompt(attempt_no)
    maeku = PromptTemplates.sample_maeku
    persona = "世を捨てた庵の主として"
    concrete_theme = "山の露、秋風"
    part = "5音（第1句）"

    prompt = PromptTemplates.build_new_prompt(maeku, persona, concrete_theme, part)
    output = @client.generate(prompt, temperature: 0.6)

    {
      condition: 'B',
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      concrete_theme: concrete_theme,
      prompt_type: 'new',
      output: output,
      maeku_preserved: check_maeku_preservation(output, maeku),
      timestamp: Time.now.iso8601(3)
    }
  rescue StandardError => e
    {
      condition: 'B',
      attempt: attempt_no,
      maeku: maeku,
      persona: persona,
      concrete_theme: concrete_theme,
      prompt_type: 'new',
      output: nil,
      failure: e.message,
      timestamp: Time.now.iso8601(3)
    }
  end

  def save_results
    path = File.expand_path('../../../tmp/experiments/prompt_redesign_v1_results.jsonl', __FILE__)
    File.open(path, 'w') do |f|
      @results.each do |result|
        # T5: 音数検証（KuValidator読み取り専用）
        if result[:output]
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
    puts "A条件（旧型）: #{@results.count { |r| r[:condition] == 'A' && r[:output] }}件完走"
    puts "B条件（新型）: #{@results.count { |r| r[:condition] == 'B' && r[:output] }}件完走"
    puts "前句保持（A）: #{@results.count { |r| r[:condition] == 'A' && r[:maeku_preserved] }}件"
    puts "前句保持（B）: #{@results.count { |r| r[:condition] == 'B' && r[:maeku_preserved] }}件"
  end
end

if __FILE__ == $0
  experiment = PromptRedesignExperiment.new
  experiment.run
end
