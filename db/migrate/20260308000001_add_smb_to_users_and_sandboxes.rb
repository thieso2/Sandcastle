class AddSmbToUsersAndSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :smb_password, :text
    add_column :sandboxes, :smb_enabled, :boolean, default: false, null: false
  end
end
