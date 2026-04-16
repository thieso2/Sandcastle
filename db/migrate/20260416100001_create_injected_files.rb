class CreateInjectedFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :injected_files do |t|
      t.references :user, null: false, foreign_key: true
      t.string :path, null: false
      t.text :content
      t.integer :mode, null: false, default: 0o600
      t.timestamps
    end

    add_index :injected_files, [ :user_id, :path ], unique: true
  end
end
