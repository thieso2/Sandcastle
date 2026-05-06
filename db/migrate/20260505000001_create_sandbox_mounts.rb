class CreateSandboxMounts < ActiveRecord::Migration[8.1]
  def change
    create_table :sandbox_mounts do |t|
      t.references :sandbox, null: false, foreign_key: true
      t.string :mount_type, null: false
      t.string :storage_mode, null: false, default: "direct"
      t.string :state, null: false, default: "active"
      t.string :logical_path
      t.string :target_path, null: false
      t.string :master_path, null: false
      t.string :source_path, null: false
      t.string :base_path
      t.string :work_path
      t.timestamps
    end

    add_index :sandbox_mounts, [ :sandbox_id, :target_path ], unique: true
    add_index :sandbox_mounts, [ :sandbox_id, :mount_type, :logical_path ],
      name: "index_sandbox_mounts_on_sandbox_type_and_logical_path"
    add_index :sandbox_mounts, [ :storage_mode, :state ]
  end
end
