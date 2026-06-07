# frozen_string_literal: true

class RengaChecker
  def initialize(sentences)
    @sentences = sentences
  end

  def check
    raw = OllamaClient.generate(build_prompt)
    json = raw.match(/\{.*\}/m)&.to_s
    parsed = JSON.parse(json)
    {
      "result"    => parsed["result"],
      "issues"    => Array(parsed["issues"]),
      "breakdown" => Array(parsed["breakdown"])
    }
  rescue JSON::ParserError, TypeError
    { "result" => "unknown", "issues" => ["式目チェックの解析に失敗しました"], "breakdown" => [] }
  end

  private

  def build_prompt
    list = @sentences.each_with_index
                     .map { |s, i| "#{i + 1}. #{s}" }.join("\n")
    <<~PROMPT
      あなたは連歌の書記役です。
      以下の句について、3点のみをチェックしてください。
      句の良し悪しや情趣の評価は行わないでください。

      【字数は音（モーラ）で数える】
      漢字は正しい読みに直してから音を数えること。
      - 拗音（みょ等）＝1音、促音（っ）＝1音、撥音（ん）＝1音

      【数え方の手本】
      - 「時雨は晴れて」→ し・ぐ・れ・は・は・れ・て ＝ 7音
      - 「妙高の」→ みょ・う・こ・う・の ＝ 5音

      【チェック項目】
      1. 字数：五七五（5/7/5音）または七七（7/7音）になっているか
      2. 去嫌：直前2句以内に同じ言葉が使われていないか（助詞を除く）
      3. 定座：月・花が2句連続、恋が3句超え連続していないか

      【検査対象（古い順）】
      #{list}

      以下のJSON形式のみで返答してください（前後に説明文を付けない）。
      {"result": "ok または ng", "issues": ["違反内容。無ければ空配列"], "breakdown": ["各句の音分解"]}
    PROMPT
  end
end
