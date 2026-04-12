class Waka < ApplicationRecord
  validates :upper_phrase_text, presence: true
  validates :lower_phrase_text, presence: true

  # フラグ定数
  FLAG_TYPES = {
    0 => 'なし',
    1 => '注（上下句分割不確実）'
  }.freeze

  def flag_label
    FLAG_TYPES[flag] || 'なし'
  end
end
