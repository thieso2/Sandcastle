class CreateSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :snapshots do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :label
      t.string :source_sandbox
      t.string :docker_image
      t.string :home_snapshot
      t.string :data_snapshot
      t.string :data_subdir
      t.bigint :docker_size
      t.bigint :home_size
      t.bigint :data_size

      t.timestamps
    end

    add_index :snapshots, [ :user_id, :name ], unique: true
  end
end
