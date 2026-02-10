class AddTailscaleAutoConnectToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tailscale_auto_connect, :boolean, default: false, null: false
  end
end
