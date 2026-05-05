class AddHomePathToSandboxes < ActiveRecord::Migration[8.0]
  def change
    add_column :sandboxes, :home_path, :string
  end
end
