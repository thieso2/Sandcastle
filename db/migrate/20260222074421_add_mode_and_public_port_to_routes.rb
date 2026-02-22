class AddModeAndPublicPortToRoutes < ActiveRecord::Migration[8.1]
  def change
    add_column :routes, :mode, :string, null: false, default: "http"
    add_column :routes, :public_port, :integer
    change_column_null :routes, :domain, true
    add_index :routes, :public_port, unique: true, where: "public_port IS NOT NULL"
  end
end
