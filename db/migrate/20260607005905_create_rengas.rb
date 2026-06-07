class CreateRengas < ActiveRecord::Migration[7.2]
  def change
    create_table :rengas do |t|
      t.text :maeku
      t.text :tsugeku
      t.string :maeku_author
      t.string :tsugeku_author
      t.string :generated_by_model
      t.jsonb :style_check_result
      t.jsonb :honka_reference

      t.timestamps
    end
  end
end
