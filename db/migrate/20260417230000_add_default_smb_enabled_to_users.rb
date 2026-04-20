class AddDefaultSmbEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :default_smb_enabled, :boolean, default: true, null: false
  end
end
