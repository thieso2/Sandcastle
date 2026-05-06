class CreateProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :projects do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :path, null: false
      t.string :image, null: false, default: "ghcr.io/thieso2/sandcastle-sandbox:latest"
      t.boolean :tailscale, null: false, default: false
      t.boolean :vnc_enabled, null: false, default: true
      t.string :vnc_geometry, null: false, default: "1280x900"
      t.integer :vnc_depth, null: false, default: 24
      t.boolean :docker_enabled, null: false, default: true
      t.boolean :smb_enabled, null: false, default: false
      t.boolean :ssh_start_tmux, null: false, default: true
      t.timestamps
    end

    add_index :projects, [ :user_id, :name ], unique: true
  end
end
