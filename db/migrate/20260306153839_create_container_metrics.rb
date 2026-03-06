class CreateContainerMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :container_metrics do |t|
      t.references :sandbox, null: false, foreign_key: true
      t.float :cpu_percent, null: false
      t.float :memory_mb, null: false
      t.datetime :recorded_at, null: false
    end

    add_index :container_metrics, [ :sandbox_id, :recorded_at ]
  end
end
