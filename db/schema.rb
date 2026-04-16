# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_16_100003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "prefix", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["prefix"], name: "index_api_tokens_on_prefix", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "container_metrics", force: :cascade do |t|
    t.float "cpu_percent", null: false
    t.float "memory_mb", null: false
    t.datetime "recorded_at", null: false
    t.bigint "sandbox_id", null: false
    t.index ["sandbox_id", "recorded_at"], name: "index_container_metrics_on_sandbox_id_and_recorded_at"
    t.index ["sandbox_id"], name: "index_container_metrics_on_sandbox_id"
  end

  create_table "device_codes", force: :cascade do |t|
    t.integer "api_token_id"
    t.string "client_name"
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "user_code", null: false
    t.integer "user_id"
    t.index ["api_token_id"], name: "index_device_codes_on_api_token_id"
    t.index ["code"], name: "index_device_codes_on_code", unique: true
    t.index ["user_code"], name: "index_device_codes_on_user_code"
    t.index ["user_id"], name: "index_device_codes_on_user_id"
  end

  create_table "ignored_paths", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "path", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "path"], name: "index_ignored_paths_on_user_id_and_path", unique: true
    t.index ["user_id"], name: "index_ignored_paths_on_user_id"
  end

  create_table "injected_files", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.integer "mode", default: 384, null: false
    t.string "path", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "path"], name: "index_injected_files_on_user_id_and_path", unique: true
    t.index ["user_id"], name: "index_injected_files_on_user_id"
  end

  create_table "invites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at"
    t.bigint "invited_by_id", null: false
    t.text "message"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_invites_on_email"
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
    t.index ["token"], name: "index_invites_on_token", unique: true
  end

  create_table "oauth_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["provider", "uid"], name: "index_oauth_identities_on_provider_and_uid", unique: true
    t.index ["user_id", "provider"], name: "index_oauth_identities_on_user_id_and_provider", unique: true
    t.index ["user_id"], name: "index_oauth_identities_on_user_id"
  end

  create_table "persisted_paths", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "path", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "path"], name: "index_persisted_paths_on_user_id_and_path", unique: true
    t.index ["user_id"], name: "index_persisted_paths_on_user_id"
  end

  create_table "routes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain"
    t.string "mode", default: "http", null: false
    t.integer "port", default: 8080, null: false
    t.integer "public_port"
    t.integer "sandbox_id", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_routes_on_domain", unique: true
    t.index ["public_port"], name: "index_routes_on_public_port", unique: true, where: "(public_port IS NOT NULL)"
    t.index ["sandbox_id"], name: "index_routes_on_sandbox_id"
  end

  create_table "sandboxes", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "container_id"
    t.datetime "created_at", null: false
    t.string "data_path"
    t.boolean "docker_enabled", default: true, null: false
    t.string "image", default: "ghcr.io/thieso2/sandcastle-sandbox:latest", null: false
    t.datetime "image_built_at"
    t.string "image_id"
    t.string "image_version"
    t.text "job_error"
    t.datetime "job_started_at"
    t.string "job_status"
    t.boolean "mount_home", default: false, null: false
    t.string "name", null: false
    t.boolean "persistent_volume", default: false, null: false
    t.boolean "smb_enabled", default: false, null: false
    t.integer "ssh_port"
    t.string "status", default: "pending", null: false
    t.boolean "tailscale", default: false, null: false
    t.boolean "temporary", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "vnc_depth", default: 24, null: false
    t.boolean "vnc_enabled", default: true, null: false
    t.string "vnc_geometry", default: "1280x900", null: false
    t.string "volume_path"
    t.index ["container_id"], name: "index_sandboxes_on_container_id", unique: true
    t.index ["job_status"], name: "index_sandboxes_on_job_status"
    t.index ["ssh_port"], name: "index_sandboxes_on_ssh_port", unique: true, where: "(((status)::text <> ALL (ARRAY[('destroyed'::character varying)::text, ('archived'::character varying)::text])) AND (ssh_port IS NOT NULL))"
    t.index ["user_id", "job_status"], name: "index_sandboxes_on_user_id_and_job_status"
    t.index ["user_id", "name"], name: "index_sandboxes_on_user_id_and_name", unique: true, where: "((status)::text <> ALL (ARRAY[('destroyed'::character varying)::text, ('archived'::character varying)::text]))"
    t.index ["user_id"], name: "index_sandboxes_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_data_path"
    t.boolean "default_docker_enabled", default: true, null: false
    t.boolean "default_mount_home", default: false, null: false
    t.boolean "default_vnc_enabled", default: true, null: false
    t.string "github_client_id"
    t.text "github_client_secret"
    t.string "google_client_id"
    t.text "google_client_secret"
    t.integer "sandbox_archive_retention_days", default: 30, null: false
    t.string "smtp_address"
    t.string "smtp_authentication", default: "plain"
    t.string "smtp_from_address"
    t.text "smtp_password"
    t.integer "smtp_port", default: 587
    t.boolean "smtp_starttls", default: true
    t.string "smtp_username"
    t.datetime "updated_at", null: false
  end

  create_table "snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "data_size"
    t.string "data_snapshot"
    t.string "data_subdir"
    t.string "docker_image"
    t.bigint "docker_size"
    t.bigint "home_size"
    t.string "home_snapshot"
    t.string "label"
    t.string "name", null: false
    t.string "source_sandbox"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "name"], name: "index_snapshots_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_snapshots_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.boolean "chrome_persist_profile", default: true, null: false
    t.datetime "created_at", null: false
    t.jsonb "custom_links", default: []
    t.string "email_address", null: false
    t.string "full_name"
    t.string "github_username"
    t.boolean "must_change_password", default: false, null: false
    t.string "name", null: false
    t.string "network_name"
    t.string "network_subnet"
    t.string "password_digest", null: false
    t.integer "sandbox_archive_retention_days"
    t.text "smb_password"
    t.jsonb "ssh_keys", default: []
    t.text "ssh_public_key"
    t.string "status", default: "active", null: false
    t.string "tailscale_auth_key"
    t.boolean "tailscale_auto_connect", default: false, null: false
    t.string "tailscale_container_id"
    t.string "tailscale_network"
    t.string "tailscale_state", default: "disabled", null: false
    t.string "tailscale_subnet"
    t.string "terminal_emulator", default: "xterm"
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
    t.check_constraint "sandbox_archive_retention_days IS NULL OR sandbox_archive_retention_days >= 0", name: "users_sandbox_archive_retention_days_non_negative"
  end

  add_foreign_key "api_tokens", "users"
  add_foreign_key "container_metrics", "sandboxes"
  add_foreign_key "device_codes", "api_tokens"
  add_foreign_key "device_codes", "users"
  add_foreign_key "ignored_paths", "users"
  add_foreign_key "injected_files", "users"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "oauth_identities", "users"
  add_foreign_key "persisted_paths", "users"
  add_foreign_key "routes", "sandboxes"
  add_foreign_key "sandboxes", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "snapshots", "users"
end
