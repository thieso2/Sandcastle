class CreatePersistedPaths < ActiveRecord::Migration[8.1]
  def up
    create_table :persisted_paths do |t|
      t.references :user, null: false, foreign_key: true
      t.string :path, null: false
      t.timestamps
    end

    add_index :persisted_paths, [ :user_id, :path ], unique: true

    execute(<<~SQL)
      INSERT INTO persisted_paths (user_id, path, created_at, updated_at)
      SELECT id, '.claude', NOW(), NOW() FROM users
      UNION ALL
      SELECT id, '.codex', NOW(), NOW() FROM users
    SQL
  end

  def down
    drop_table :persisted_paths
  end
end
