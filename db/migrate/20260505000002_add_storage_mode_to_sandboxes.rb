class AddStorageModeToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :storage_mode, :string, null: false, default: "direct"
    add_index :sandboxes, :storage_mode
  end
end
