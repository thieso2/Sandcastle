class AddCustomLinksToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :custom_links, :jsonb, default: []
  end
end
