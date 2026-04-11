class Waka < ApplicationRecord
  validates :upper_phrase_text, presence: true
  validates :lower_phrase_text, presence: true
end
