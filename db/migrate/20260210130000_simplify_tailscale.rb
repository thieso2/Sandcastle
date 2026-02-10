class SimplifyTailscale < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tailscale_auth_key, :string

    remove_column :users, :tailscale_container_id, :string
    remove_column :users, :tailscale_network, :string
    remove_column :users, :tailscale_state, :string, default: "disabled", null: false
  end
end
