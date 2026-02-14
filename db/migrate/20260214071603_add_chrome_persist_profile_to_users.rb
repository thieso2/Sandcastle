class AddChromePersistProfileToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :chrome_persist_profile, :boolean, default: true, null: false
  end
end
