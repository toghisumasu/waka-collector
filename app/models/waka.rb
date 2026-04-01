class Waka < ApplicationRecord
  validates :upper_phrase, presence: true
  validates :lower_phrase, presence: true
end
