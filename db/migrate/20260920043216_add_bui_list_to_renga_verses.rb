class AddBuiListToRengaVerses < ActiveRecord::Migration[7.2]
  def change
    add_column :renga_verses, :bui_list, :text, array: true, default: []
  end
end
