# frozen_string_literal: true

module LabelBot
  # ボタン配置と callback_data の生成・解析。
  # callback_data は "v|<item_id>|<code>"（値）または "t|<item_id>|<code>"（タグ）。
  # Telegram の上限（64 バイト）に収めるため、値・タグは 1 文字コードにする。
  module Keyboard
    VALUES = { "y" => "描ける", "n" => "描けない" }.freeze
    TAGS   = { "g" => "文法・意味", "w" => "言葉", "o" => "その他" }.freeze
    ID_PATTERN = /\A[A-Za-z0-9_-]{1,40}\z/

    module_function

    def valid_id?(id)
      id.to_s.match?(ID_PATTERN)
    end

    def data(field, item_id, code)
      "#{field}|#{item_id}|#{code}"
    end

    # 戻り値: [field("value"|"tag"), item_id, 保存する値] / 不正なら nil
    def parse(callback_data)
      kind, item_id, code = callback_data.to_s.split("|", 3)
      return nil unless valid_id?(item_id)

      case kind
      when "v" then VALUES[code] && [ "value", item_id, VALUES[code] ]
      when "t" then TAGS[code] && [ "tag", item_id, TAGS[code] ]
      end
    end

    # value: 現在の値(String|nil)、tags: 付いているタグ(Array)
    def markup(item_id, value: nil, tags: [])
      mark = ->(on, label) { on ? "✓ #{label}" : label }
      {
        inline_keyboard: [
          VALUES.map { |code, label| { text: mark.(value == label, label), callback_data: data("v", item_id, code) } },
          TAGS.map { |code, label| { text: mark.(tags.include?(label), label), callback_data: data("t", item_id, code) } }
        ]
      }
    end
  end
end
