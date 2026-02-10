class AddRouteToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :route_domain, :string
    add_column :sandboxes, :route_port, :integer, default: 8080

    add_index :sandboxes, :route_domain, unique: true,
      where: "route_domain IS NOT NULL AND status != 'destroyed'",
      name: "index_sandboxes_on_route_domain_unique_active"
  end
end
