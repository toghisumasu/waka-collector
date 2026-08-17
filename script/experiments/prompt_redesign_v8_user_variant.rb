#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（差分検証・ユーザー提示版）: ユーザーが個人的に手を加えたプロンプト案の検証
#
# 依頼書§10-8のv6（【音の目安】追加）・v7（【音の目安】＋【出力】追加）は
# いずれもB条件を再現しなかった。本スクリプトはユーザーがv6のプロンプトに
# 個人的に手を加えた案（persona文言・scene_narrative文言・出力指示文言・
# 【出力】ラベルの有無を含め複数箇所を同時に変更したもの）を検証する。
# v6/v7のような単一変数の差分検証ではなく、ユーザー案そのものを固定文字列と
# して実行する（D-T10-1に従いverbatim全文は
# script/experiments/prompts/v8_user_variant_prompt.txt に保存済み）。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v8_user_variant.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v8_user_variant_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

PROMPT_PATH = File.expand_path('prompts/v8_user_variant_prompt.txt', __dir__)

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

class UserVariantExperiment
  MAEKU = "はるゝまも袖は時雨の旅衣"
  THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v8_user_variant_results.jsonl', __FILE__)

  def initialize(prompt_path: PROMPT_PATH, maeku: MAEKU, theme_keywords: THEME_KEYWORDS,
                 output_path: OUTPUT_PATH, attempts: 5)
    @client = OllamaExperimentClient.new('qwen3:8b')
    @results = []
    @prompt = File.read(prompt_path)
    @maeku = maeku
    @theme_keywords = theme_keywords
    @output_path = output_path
    @attempts = attempts
  end

  def run
    puts "【T10: ユーザー提示プロンプト案の検証】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    output = @client.generate(@prompt, temperature: 0.6, timeout: 1200)
    ku = ExtractVerse.call(output, @maeku)
    used_fallback = !output.to_s.include?("「#{ku}」")
    validation = KuValidator.new(ku, type: :tanku).validate

    {
      attempt: attempt_no,
      maeku: @maeku,
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
  experiment = UserVariantExperiment.new
  experiment.run
end
