class CreateIgnoredPaths < ActiveRecord::Migration[8.1]
  def change
    create_table :ignored_paths do |t|
      t.references :user, null: false, foreign_key: true
      t.string :path, null: false
      t.timestamps
    end

    add_index :ignored_paths, [ :user_id, :path ], unique: true
  end
end
