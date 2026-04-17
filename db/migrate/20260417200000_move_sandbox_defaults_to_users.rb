class MoveSandboxDefaultsToUsers < ActiveRecord::Migration[8.1]
  def up
    # Mirror the column types from settings onto users. Null is allowed on
    # booleans so we can tell "user hasn't set this yet" from "explicitly
    # off" when we want nil-coalescing fallbacks; we seed from the old
    # admin defaults below.
    add_column :users, :default_vnc_enabled, :boolean, null: true
    add_column :users, :default_mount_home, :boolean, null: true
    add_column :users, :default_docker_enabled, :boolean, null: true
    add_column :users, :default_data_path, :string

    # Seed each existing user with whatever the admin had set globally, so the
    # new-sandbox form stays consistent across the migration.
    if column_exists?(:settings, :default_vnc_enabled)
      setting = select_one("SELECT default_vnc_enabled, default_mount_home, default_docker_enabled, default_data_path FROM settings ORDER BY id LIMIT 1")
      if setting
        execute <<~SQL.squish
          UPDATE users SET
            default_vnc_enabled   = #{connection.quote(setting["default_vnc_enabled"])},
            default_mount_home    = #{connection.quote(setting["default_mount_home"])},
            default_docker_enabled = #{connection.quote(setting["default_docker_enabled"])},
            default_data_path     = #{connection.quote(setting["default_data_path"])}
        SQL
      end
    end

    remove_column :settings, :default_vnc_enabled
    remove_column :settings, :default_mount_home
    remove_column :settings, :default_docker_enabled
    remove_column :settings, :default_data_path
  end

  def down
    add_column :settings, :default_vnc_enabled, :boolean, default: true, null: false
    add_column :settings, :default_mount_home, :boolean, default: false, null: false
    add_column :settings, :default_docker_enabled, :boolean, default: true, null: false
    add_column :settings, :default_data_path, :string

    remove_column :users, :default_vnc_enabled
    remove_column :users, :default_mount_home
    remove_column :users, :default_docker_enabled
    remove_column :users, :default_data_path
  end
end
