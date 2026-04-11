class ChangeWakaColumns < ActiveRecord::Migration[7.2]
  def change
    # 既存カラムの用途変更（上の句・下の句をかな交じり文に）
    rename_column :wakas, :upper_phrase, :upper_phrase_text
    rename_column :wakas, :lower_phrase, :lower_phrase_text

    # 読み仮名カラムを追加
    add_column :wakas, :upper_phrase_yomi, :string
    add_column :wakas, :lower_phrase_yomi, :string
  end
end
