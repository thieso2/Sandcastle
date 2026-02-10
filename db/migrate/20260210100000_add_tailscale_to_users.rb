class AddTailscaleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tailscale_enabled, :boolean, default: false, null: false
    add_column :users, :tailscale_container_id, :string
    add_column :users, :tailscale_network, :string
  end
end
