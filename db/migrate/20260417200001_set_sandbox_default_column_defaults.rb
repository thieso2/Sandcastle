class SetSandboxDefaultColumnDefaults < ActiveRecord::Migration[8.1]
  # Separate migration so fresh installs don't need to re-run the data copy
  # from the previous step; this only sets column-level defaults used when a
  # new user record is built.
  def change
    change_column_default :users, :default_vnc_enabled,    from: nil, to: true
    change_column_default :users, :default_mount_home,     from: nil, to: false
    change_column_default :users, :default_docker_enabled, from: nil, to: true
  end
end
