#!/usr/bin/env ruby
# frozen_string_literal: true

# T10（本筋再検証）: プロンプト文面をB条件と完全同一に固定し、実行パラメータのみ
# 手動curl実行相当に揃えた版（依頼書§10-8）
#
# 背景: v4〜v8はいずれもプロンプトの文面・構造を変えてB条件（narrative_4、
# theme_echo平均0.2語）の再現を試みたが、ラベル構造の全差分候補（【音の目安】・
# 【出力】の有無）を検証してもB条件を再現しなかった。プロンプト文面ではなく
# 「実行時パラメータ」がB条件との差分である可能性を検証する。
#
# 現行のOllamaExperimentClient（prompt_redesign_v1.rb）は、生成メソッドの
# デフォルト値としてtemperature: 0.6を必ずpayloadに含めて送信している。
# 元のB条件（narrative_4_x5）はcurlによる手動実行だったと記録されており、
# curlコマンドにtemperatureを明示的に指定していなければ、Ollama側の
# モデルファイル定義によるデフォルト値（qwen3:8bの場合、明示指定がなければ
# Modelfile側の値。指定がなければOllama側の一般的な既定値）が使われていた
# はずである。本スクリプトはtemperatureキーをpayloadから完全に省略し、
# Ollama側のデフォルト挙動に委ねることで、この差を検証する。
#
# stream: falseは維持する（単発のJSONレスポンスとしてパースする必要があるため。
# 元のcurl実行がstream:trueだった場合とは異なる可能性が残るが、手動でraw_response
# を1つのテキストとして得ていた記録と整合するため、ここでは変更しない）。
#
# プロンプト文面はv5（prompt_redesign_v5_extract_verse_no_mora.rb）と
# 完全同一（B条件の再構成：トップ指示文＋【前句】＋【あなたの配役】＋
# scene_narrativeの地の文＋「」出力指示、【音の目安】【出力】ラベルなし）。
# persona・scene_narrativeの文言もv5のデフォルトから変更しない。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v9_curl_equivalent_params.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v9_curl_equivalent_params_results.jsonl（5行）

require_relative 'prompt_redesign_v2'

# temperatureキー自体をpayloadから省略するクライアント。
# OllamaExperimentClient#generateは常にtemperatureをpayloadへ含めるため、
# 「未指定」を検証するには専用のリクエスト実装が必要。
class CurlEquivalentClient
  DEFAULT_ENDPOINT = 'http://localhost:11434/api/generate'

  def initialize(model = 'qwen3:8b', endpoint = DEFAULT_ENDPOINT)
    @model = model
    @endpoint = endpoint
  end

  def generate(prompt, timeout: 1200)
    uri = URI(@endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = timeout
    http.write_timeout = timeout

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'

    payload = {
      model: @model,
      prompt: prompt,
      stream: false
      # temperatureキーは意図的に省略（Ollama側のデフォルト挙動を検証するため）
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

# B条件の再構成プロンプト（v5と同一、変更なし）
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

class CurlEquivalentParamsExperiment
  DEFAULT_MAEKU = "はるゝまも袖は時雨の旅衣"
  DEFAULT_PERSONA = "世を捨てた庵の主として"
  DEFAULT_SCENE_NARRATIVE = "遠くの寺から鐘の音が微かに響き、枯れた野の道を風が渡っていくような、\nそのような情景の中で句を詠んでください。"
  DEFAULT_THEME_KEYWORDS = %w[寺 鐘 枯 野 道 風].freeze
  DEFAULT_OUTPUT_PATH = File.expand_path('../../../tmp/experiments/prompt_redesign_v9_curl_equivalent_params_results.jsonl', __FILE__)

  def initialize(maeku: DEFAULT_MAEKU, persona: DEFAULT_PERSONA, scene_narrative: DEFAULT_SCENE_NARRATIVE,
                 theme_keywords: DEFAULT_THEME_KEYWORDS, output_path: DEFAULT_OUTPUT_PATH, attempts: 5)
    @client = CurlEquivalentClient.new('qwen3:8b')
    @results = []
    @maeku = maeku
    @persona = persona
    @scene_narrative = scene_narrative
    @theme_keywords = theme_keywords
    @output_path = output_path
    @attempts = attempts
  end

  def run
    puts "【T10: 実行パラメータをcurl相当に揃えた版（temperature未指定）】"
    @attempts.times { |i| @results << generate(i + 1) }
    save_results
    print_summary
  end

  private

  def generate(attempt_no)
    prompt = PromptTemplates.build_scene_narrative_prompt_no_mora(@maeku, @persona, @scene_narrative)
    output = @client.generate(prompt, timeout: 1200)
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
  experiment = CurlEquivalentParamsExperiment.new
  experiment.run
end
