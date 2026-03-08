class AddNetworkToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :network_name, :string
    add_column :users, :network_subnet, :string
  end
end
