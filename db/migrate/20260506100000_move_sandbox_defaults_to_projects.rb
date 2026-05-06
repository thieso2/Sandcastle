class MoveSandboxDefaultsToProjects < ActiveRecord::Migration[8.1]
  def up
    change_column_null :projects, :path, true

    add_column :projects, :default_project, :boolean, null: false, default: false
    add_column :projects, :mount_home, :boolean, null: false, default: false
    add_column :projects, :home_path, :string
    add_column :projects, :data_path, :string
    add_column :projects, :oidc_enabled, :boolean, null: false, default: false
    add_column :projects, :gcp_oidc_enabled, :boolean, null: false, default: false
    add_reference :projects, :gcp_oidc_config, foreign_key: true
    add_column :projects, :gcp_service_account_email, :string
    add_column :projects, :gcp_principal_scope, :string, null: false, default: "user"
    add_column :projects, :gcp_roles, :jsonb, null: false, default: []

    add_index :projects, [ :user_id, :default_project ],
      unique: true,
      where: "default_project = TRUE",
      name: "index_projects_on_user_id_default_project"

    execute <<~SQL.squish
      UPDATE projects
      SET default_project = TRUE,
          mount_home = COALESCE(users.default_mount_home, FALSE),
          data_path = NULLIF(users.default_data_path, ''),
          oidc_enabled = COALESCE(users.default_oidc_enabled, FALSE),
          updated_at = CURRENT_TIMESTAMP
      FROM users
      WHERE projects.user_id = users.id
        AND projects.name = 'default'
        AND NOT EXISTS (
          SELECT 1 FROM projects existing_default
          WHERE existing_default.user_id = users.id
            AND existing_default.default_project = TRUE
        )
    SQL

    execute <<~SQL.squish
      INSERT INTO projects (
        user_id, name, path, image, tailscale, vnc_enabled, vnc_geometry, vnc_depth,
        docker_enabled, smb_enabled, ssh_start_tmux, default_project, mount_home,
        data_path, oidc_enabled, gcp_oidc_enabled, gcp_oidc_config_id,
        gcp_service_account_email, gcp_principal_scope, gcp_roles, created_at, updated_at
      )
      SELECT
        users.id,
        'default',
        NULL,
        'ghcr.io/thieso2/sandcastle-sandbox:latest',
        FALSE,
        COALESCE(users.default_vnc_enabled, TRUE),
        '1280x900',
        24,
        COALESCE(users.default_docker_enabled, TRUE),
        COALESCE(users.default_smb_enabled, FALSE) AND users.tailscale_state = 'enabled' AND users.smb_password IS NOT NULL,
        COALESCE(users.default_ssh_start_tmux, TRUE),
        TRUE,
        COALESCE(users.default_mount_home, FALSE),
        NULLIF(users.default_data_path, ''),
        COALESCE(users.default_oidc_enabled, FALSE),
        FALSE,
        NULL,
        NULL,
        'user',
        '[]'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM users
      WHERE NOT EXISTS (
        SELECT 1 FROM projects
        WHERE projects.user_id = users.id
          AND projects.default_project = TRUE
      )
    SQL

    execute <<~SQL.squish
      UPDATE projects
      SET gcp_oidc_config_id = first_config.id,
          gcp_oidc_enabled = CASE WHEN projects.oidc_enabled THEN TRUE ELSE projects.gcp_oidc_enabled END,
          updated_at = CURRENT_TIMESTAMP
      FROM (
        SELECT DISTINCT ON (user_id) id, user_id
        FROM gcp_oidc_configs
        ORDER BY user_id, id
      ) first_config
      WHERE projects.default_project = TRUE
        AND projects.user_id = first_config.user_id
        AND projects.oidc_enabled = TRUE
        AND projects.gcp_oidc_config_id IS NULL
    SQL
  end

  def down
    remove_index :projects, name: "index_projects_on_user_id_default_project"
    remove_reference :projects, :gcp_oidc_config, foreign_key: true
    remove_column :projects, :gcp_roles
    remove_column :projects, :gcp_principal_scope
    remove_column :projects, :gcp_service_account_email
    remove_column :projects, :gcp_oidc_enabled
    remove_column :projects, :oidc_enabled
    remove_column :projects, :data_path
    remove_column :projects, :home_path
    remove_column :projects, :mount_home
    remove_column :projects, :default_project
    change_column_null :projects, :path, false
  end
end
