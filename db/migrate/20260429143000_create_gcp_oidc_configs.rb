class CreateGcpOidcConfigs < ActiveRecord::Migration[8.1]
  def up
    create_table :gcp_oidc_configs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :project_id
      t.string :project_number, null: false
      t.string :workload_identity_pool_id, null: false
      t.string :workload_identity_provider_id, null: false
      t.string :workload_identity_location, null: false, default: "global"
      t.timestamps
    end

    add_index :gcp_oidc_configs, [ :user_id, :name ], unique: true
    add_reference :sandboxes, :gcp_oidc_config, foreign_key: true

    execute <<~SQL.squish
      INSERT INTO gcp_oidc_configs (
        user_id, name, project_id, project_number,
        workload_identity_pool_id, workload_identity_provider_id,
        workload_identity_location, created_at, updated_at
      )
      SELECT
        id,
        COALESCE(NULLIF(gcp_project_id, ''), 'GCP ' || gcp_project_number),
        NULLIF(gcp_project_id, ''),
        gcp_project_number,
        gcp_workload_identity_pool_id,
        gcp_workload_identity_provider_id,
        COALESCE(NULLIF(gcp_workload_identity_location, ''), 'global'),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM users
      WHERE NULLIF(gcp_project_number, '') IS NOT NULL
        AND NULLIF(gcp_workload_identity_pool_id, '') IS NOT NULL
        AND NULLIF(gcp_workload_identity_provider_id, '') IS NOT NULL
    SQL

    execute <<~SQL.squish
      UPDATE sandboxes
      SET gcp_oidc_config_id = (
        SELECT gcp_oidc_configs.id
        FROM gcp_oidc_configs
        WHERE gcp_oidc_configs.user_id = sandboxes.user_id
        ORDER BY gcp_oidc_configs.id
        LIMIT 1
      )
      WHERE sandboxes.gcp_oidc_enabled = TRUE
    SQL

    remove_column :users, :gcp_project_id
    remove_column :users, :gcp_project_number
    remove_column :users, :gcp_workload_identity_pool_id
    remove_column :users, :gcp_workload_identity_provider_id
    remove_column :users, :gcp_workload_identity_location
  end

  def down
    add_column :users, :gcp_project_id, :string
    add_column :users, :gcp_project_number, :string
    add_column :users, :gcp_workload_identity_pool_id, :string
    add_column :users, :gcp_workload_identity_provider_id, :string
    add_column :users, :gcp_workload_identity_location, :string, null: false, default: "global"

    execute <<~SQL.squish
      UPDATE users
      SET
        gcp_project_id = first_config.project_id,
        gcp_project_number = first_config.project_number,
        gcp_workload_identity_pool_id = first_config.workload_identity_pool_id,
        gcp_workload_identity_provider_id = first_config.workload_identity_provider_id,
        gcp_workload_identity_location = first_config.workload_identity_location
      FROM (
        SELECT DISTINCT ON (user_id) *
        FROM gcp_oidc_configs
        ORDER BY user_id, id
      ) first_config
      WHERE first_config.user_id = users.id
    SQL

    remove_reference :sandboxes, :gcp_oidc_config, foreign_key: true
    drop_table :gcp_oidc_configs
  end
end
