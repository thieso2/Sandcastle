class AddVncOptionsToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :vnc_enabled, :boolean, default: true, null: false
    add_column :sandboxes, :vnc_geometry, :string, default: "1280x900", null: false
    add_column :sandboxes, :vnc_depth, :integer, default: 24, null: false
  end
end
