class AddImageVersionToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :image_version, :string
  end
end
