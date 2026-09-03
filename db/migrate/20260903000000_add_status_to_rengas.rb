class AddStatusToRengas < ActiveRecord::Migration[7.2]
  def change
    add_column :rengas, :status, :string, default: "pending", null: false
  end
end
