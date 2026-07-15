class AddObservationBatchToRengas < ActiveRecord::Migration[7.2]
  def change
    add_column :rengas, :observation_batch, :string
  end
end
