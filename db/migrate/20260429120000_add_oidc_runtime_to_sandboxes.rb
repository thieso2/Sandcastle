class AddOidcRuntimeToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :default_oidc_enabled, :boolean, null: false, default: false

    add_column :sandboxes, :oidc_enabled, :boolean, null: false, default: false
    add_column :sandboxes, :oidc_secret_digest, :string
    add_column :sandboxes, :oidc_secret_rotated_at, :datetime
  end
end
