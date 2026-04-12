class AddFlagToWakas < ActiveRecord::Migration[7.2]
  def change
    add_column :wakas, :flag, :integer
  end
end
