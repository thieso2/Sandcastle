class AddTailscaleSubnetToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tailscale_subnet, :string
  end
end
