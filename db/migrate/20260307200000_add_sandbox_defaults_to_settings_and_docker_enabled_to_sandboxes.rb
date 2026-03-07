class AddSandboxDefaultsToSettingsAndDockerEnabledToSandboxes < ActiveRecord::Migration[8.1]
  def change
    # Per-sandbox docker daemon toggle
    add_column :sandboxes, :docker_enabled, :boolean, default: true, null: false

    # System-wide sandbox defaults (admin settings)
    add_column :settings, :default_vnc_enabled, :boolean, default: true, null: false
    add_column :settings, :default_mount_home, :boolean, default: false, null: false
    add_column :settings, :default_data_path, :string
    add_column :settings, :default_docker_enabled, :boolean, default: true, null: false
  end
end
