class CreateRengaWorks < ActiveRecord::Migration[7.1]
  def change
    create_table :renga_works do |t|
      t.string :slug, null: false          # 例: yuyama_sangin
      t.string :title, null: false         # 湯山三吟百韻
      t.string :style                      # minase / yugama など
      t.string :form                       # 三吟 / 独吟
      t.string :composed_on                # 延徳三年十月二十日
      t.string :authors                    # 肖柏・宗長・宗祇
      t.string :source                     # 出典(紀要の去嫌一覧など)
      t.string :data_status, default: "draft"  # draft / verified
      t.timestamps
    end
    add_index :renga_works, :slug, unique: true

    create_table :renga_work_verses do |t|
      t.references :renga_work, null: false, foreign_key: true
      t.integer :verse_no, null: false
      t.string  :fold
      t.string  :kind          # 長 / 短
      t.string  :author
      t.text    :text, null: false
      t.text    :reading
      t.string  :season        # 春夏秋冬 / 雑
      t.text    :bui_list, array: true, default: []       # 強い部立(植物・動物・降物…)
      t.text    :bui_weak_list, array: true, default: []  # □印(二句以上で可の弱い部立)
      t.text    :nana_list, array: true, default: []      # 七句去物(月・松・枕・涙・衣7・夢・船・煙)
      t.text    :other_cats, array: true, default: []     # 衣類・風体・聞え気味
      t.string  :kyoken_tokens  # 去嫌表の印そのまま(木・草・朝・夕・□・×など)
      t.timestamps
    end
    add_index :renga_work_verses, [:renga_work_id, :verse_no], unique: true
  end
end
