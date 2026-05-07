class CreateSandboxAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :sandbox_aliases do |t|
      t.references :sandbox, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :value, null: false
      t.timestamps
    end

    add_index :sandbox_aliases, [ :sandbox_id, :kind, :value ], unique: true
    add_index :sandbox_aliases, :value, unique: true, where: "kind = 'fqdn'"
  end
end
