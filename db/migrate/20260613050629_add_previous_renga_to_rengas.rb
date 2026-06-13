class AddPreviousRengaToRengas < ActiveRecord::Migration[7.2]
  def change
    add_column :rengas, :previous_renga_id, :bigint
  end
end
