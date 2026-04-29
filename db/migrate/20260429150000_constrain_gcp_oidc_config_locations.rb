class ConstrainGcpOidcConfigLocations < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE gcp_oidc_configs
      SET workload_identity_location = 'global'
      WHERE workload_identity_location IS DISTINCT FROM 'global'
    SQL

    add_check_constraint :gcp_oidc_configs,
      "workload_identity_location = 'global'",
      name: "chk_gcp_oidc_configs_location_global"
  end

  def down
    remove_check_constraint :gcp_oidc_configs,
      name: "chk_gcp_oidc_configs_location_global"
  end
end
