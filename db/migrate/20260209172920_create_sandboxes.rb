class CreateSandboxes < ActiveRecord::Migration[8.1]
  def change
    create_table :sandboxes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :container_id
      t.string :image, default: "sandcastle-sandbox:latest", null: false
      t.string :status, default: "pending", null: false
      t.integer :ssh_port, null: false
      t.boolean :persistent_volume, default: false, null: false
      t.string :volume_path

      t.timestamps
    end
    add_index :sandboxes, [ :user_id, :name ], unique: true
    add_index :sandboxes, :ssh_port, unique: true
    add_index :sandboxes, :container_id, unique: true
  end
end
