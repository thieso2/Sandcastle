class AddSshKeysToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :ssh_keys, :jsonb, default: []

    # Migrate existing ssh_public_key data into the new ssh_keys array
    execute <<~SQL
      UPDATE users
      SET ssh_keys = jsonb_build_array(jsonb_build_object('name', 'default', 'key', ssh_public_key))
      WHERE ssh_public_key IS NOT NULL AND ssh_public_key != ''
    SQL
  end

  def down
    remove_column :users, :ssh_keys
  end
end
