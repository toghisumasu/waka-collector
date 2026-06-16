# frozen_string_literal: true

# メンタムさんに与えるツール定義と、その実行ロジックを集約する。
# RengaGenerator・RengaCheckerの両方から利用可能にする想定。
module OllamaTools
  COUNT_MORA = {
    type: "function",
    function: {
      name: "count_mora",
      description: "与えられた日本語の句のモーラ数（拍数）を正確に数える",
      parameters: {
        type: "object",
        required: ["text"],
        properties: {
          text: { type: "string", description: "モーラ数を数えたい句のテキスト" }
        }
      }
    }
  }.freeze

  # name: ツール名, arguments: Hash（Ollamaが渡す引数）
  # 戻り値はメンタムさんに to_json で返されるHash
  def self.execute(name, arguments)
    case name
    when "count_mora"
      { mora: KuValidator.new(arguments["text"]).count_mora }
    else
      { error: "unknown tool: #{name}" }
    end
  end
end

