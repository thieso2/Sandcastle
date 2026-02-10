class AddTailscaleToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :tailscale, :boolean, default: false, null: false
  end
end
