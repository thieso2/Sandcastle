class AddGcpOidcIdentityToUsersAndSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :gcp_project_id, :string
    add_column :users, :gcp_project_number, :string
    add_column :users, :gcp_workload_identity_pool_id, :string
    add_column :users, :gcp_workload_identity_provider_id, :string
    add_column :users, :gcp_workload_identity_location, :string, null: false, default: "global"

    add_column :sandboxes, :gcp_oidc_enabled, :boolean, null: false, default: false
    add_column :sandboxes, :gcp_service_account_email, :string
    add_column :sandboxes, :gcp_principal_scope, :string, null: false, default: "sandbox"
    add_column :sandboxes, :gcp_roles, :jsonb, null: false, default: []
  end
end
