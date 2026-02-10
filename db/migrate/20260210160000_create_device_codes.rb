class CreateDeviceCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :device_codes do |t|
      t.string :code, null: false
      t.string :user_code, null: false
      t.string :client_name
      t.string :status, null: false, default: "pending"
      t.references :user, foreign_key: true
      t.references :api_token, foreign_key: true
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :device_codes, :code, unique: true
    add_index :device_codes, :user_code
  end
end
