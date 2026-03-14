class CreateWakas < ActiveRecord::Migration[7.2]
  def change
    create_table :wakas do |t|
      t.string :upper_phrase
      t.string :lower_phrase
      t.string :author
      t.string :source
      t.string :era
      t.text :notes

      t.timestamps
    end
  end
end
