# frozen_string_literal: true

class RengaVerse < ApplicationRecord
  belongs_to :previous_verse, class_name: "RengaVerse", optional: true
  has_one :next_verse, class_name: "RengaVerse", foreign_key: "previous_verse_id"
  belongs_to :renga, optional: true

  TOTAL_VERSES = 100

  # 依頼書B Item 2: 百韻の折の区切り（script/log_to_html.rbの定義と一致させる。
  # 旧定義は初折表以外の各折が8句区切りの誤った近似になっていた）。
  FOLDS = [
    ["初折表", 1..8],
    ["初折裏", 9..22],
    ["二折表", 23..36],
    ["二折裏", 37..50],
    ["三折表", 51..64],
    ["三折裏", 65..78],
    ["名残表", 79..92],
    ["名残裏", 93..100]
  ].freeze

  def self.fold_for(verse_no)
    FOLDS.find { |_, range| range.cover?(verse_no) }&.first
  end
end
