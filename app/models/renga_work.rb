class RengaWork < ApplicationRecord
  has_many :renga_work_verses, -> { order(:verse_no) }, dependent: :destroy
end
