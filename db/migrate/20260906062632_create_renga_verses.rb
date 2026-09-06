class CreateRengaVerses < ActiveRecord::Migration[7.2]
  def change
    create_table :renga_verses do |t|
      t.integer :verse_no, null: false
      t.text :maeku
      t.text :tsugeku, null: false
      t.string :maeku_type
      t.string :tsugeku_type, null: false
      t.bigint :previous_verse_id
      t.bigint :renga_id

      t.timestamps
    end

    add_index :renga_verses, :verse_no
    add_index :renga_verses, :previous_verse_id
    add_index :renga_verses, :renga_id, unique: true
  end
end
