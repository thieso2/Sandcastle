class DefaultGcpPrincipalScopeToUser < ActiveRecord::Migration[8.1]
  def change
    change_column_default :sandboxes, :gcp_principal_scope, from: "sandbox", to: "user"
  end
end
