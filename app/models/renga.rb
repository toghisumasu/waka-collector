class Renga < ApplicationRecord
  belongs_to :previous_renga, class_name: "Renga", optional: true
  has_one :next_renga, class_name: "Renga", foreign_key: "previous_renga_id"
end

