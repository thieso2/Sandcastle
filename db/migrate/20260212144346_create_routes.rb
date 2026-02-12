class CreateRoutes < ActiveRecord::Migration[8.1]
  def up
    create_table :routes do |t|
      t.references :sandbox, null: false, foreign_key: true
      t.string :domain, null: false
      t.integer :port, null: false, default: 8080
      t.timestamps
    end

    add_index :routes, :domain, unique: true

    # Migrate existing route data
    execute <<~SQL
      INSERT INTO routes (sandbox_id, domain, port, created_at, updated_at)
      SELECT id, route_domain, route_port, created_at, updated_at
      FROM sandboxes
      WHERE route_domain IS NOT NULL AND status != 'destroyed'
    SQL

    remove_index :sandboxes, name: "index_sandboxes_on_route_domain_unique_active"
    remove_column :sandboxes, :route_domain
    remove_column :sandboxes, :route_port
  end

  def down
    add_column :sandboxes, :route_domain, :string
    add_column :sandboxes, :route_port, :integer, default: 8080

    execute <<~SQL
      UPDATE sandboxes SET route_domain = routes.domain, route_port = routes.port
      FROM routes WHERE routes.sandbox_id = sandboxes.id
    SQL

    add_index :sandboxes, :route_domain, unique: true,
      where: "route_domain IS NOT NULL AND status != 'destroyed'",
      name: "index_sandboxes_on_route_domain_unique_active"

    drop_table :routes
  end
end
