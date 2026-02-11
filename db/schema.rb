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

ActiveRecord::Schema[8.1].define(version: 2026_02_10_204820) do
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

  create_table "sandboxes", force: :cascade do |t|
    t.string "container_id"
    t.datetime "created_at", null: false
    t.string "data_path"
    t.string "image", default: "ghcr.io/thieso2/sandcastle-sandbox:latest", null: false
    t.boolean "mount_home", default: false, null: false
    t.string "name", null: false
    t.boolean "persistent_volume", default: false, null: false
    t.string "route_domain"
    t.integer "route_port", default: 8080
    t.integer "ssh_port", null: false
    t.string "status", default: "pending", null: false
    t.boolean "tailscale", default: false, null: false
    t.boolean "temporary", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "volume_path"
    t.index ["container_id"], name: "index_sandboxes_on_container_id", unique: true
    t.index ["route_domain"], name: "index_sandboxes_on_route_domain_unique_active", unique: true, where: "route_domain IS NOT NULL AND status != 'destroyed'"
    t.index ["ssh_port"], name: "index_sandboxes_on_ssh_port", unique: true, where: "status != 'destroyed'"
    t.index ["user_id", "name"], name: "index_sandboxes_on_user_id_and_name", unique: true, where: "status != 'destroyed'"
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

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.text "ssh_public_key"
    t.string "status", default: "active", null: false
    t.string "tailscale_auth_key"
    t.boolean "tailscale_auto_connect", default: false, null: false
    t.string "tailscale_container_id"
    t.string "tailscale_network"
    t.string "tailscale_state", default: "disabled", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
  end

  add_foreign_key "api_tokens", "users"
  add_foreign_key "device_codes", "api_tokens"
  add_foreign_key "device_codes", "users"
  add_foreign_key "oauth_identities", "users"
  add_foreign_key "sandboxes", "users"
  add_foreign_key "sessions", "users"
end
