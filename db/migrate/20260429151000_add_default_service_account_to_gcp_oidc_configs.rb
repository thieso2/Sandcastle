class AddDefaultServiceAccountToGcpOidcConfigs < ActiveRecord::Migration[8.1]
  def up
    add_column :gcp_oidc_configs, :default_service_account_email, :string

    execute <<~SQL.squish
      UPDATE gcp_oidc_configs
      SET default_service_account_email = 'sandcastle-reader@' || project_id || '.iam.gserviceaccount.com'
      WHERE NULLIF(project_id, '') IS NOT NULL
    SQL
  end

  def down
    remove_column :gcp_oidc_configs, :default_service_account_email
  end
end
