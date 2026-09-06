# frozen_string_literal: true

class RengaVerse < ApplicationRecord
  belongs_to :previous_verse, class_name: "RengaVerse", optional: true
  has_one :next_verse, class_name: "RengaVerse", foreign_key: "previous_verse_id"
  belongs_to :renga, optional: true

  TOTAL_VERSES = 100

  # 依頼書2026-09-06: 百韻の折の区切り
  FOLDS = [
    ["初折表", 1..8],
    ["初折裏", 9..14],
    ["二折表", 15..22],
    ["二折裏", 23..28],
    ["三折表", 29..36],
    ["三折裏", 37..42],
    ["名残表", 43..50],
    ["名残裏", 51..100]
  ].freeze

  def self.fold_for(verse_no)
    FOLDS.find { |_, range| range.cover?(verse_no) }&.first
  end
end
