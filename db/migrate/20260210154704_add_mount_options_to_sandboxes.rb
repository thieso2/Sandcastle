class AddMountOptionsToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :mount_home, :boolean, default: false, null: false
    add_column :sandboxes, :data_path, :string
  end
end
