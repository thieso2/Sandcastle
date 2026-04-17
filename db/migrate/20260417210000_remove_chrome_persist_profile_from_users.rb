class RemoveChromePersistProfileFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :chrome_persist_profile, :boolean, default: true, null: false
  end
end
