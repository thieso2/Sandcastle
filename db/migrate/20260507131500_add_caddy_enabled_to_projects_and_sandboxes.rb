class AddCaddyEnabledToProjectsAndSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :caddy_enabled, :boolean, null: false, default: false
    add_column :sandboxes, :caddy_enabled, :boolean, null: false, default: false
  end
end
