class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.string :name, null: false
      t.text :ssh_public_key
      t.boolean :admin, default: false, null: false
      t.string :status, default: "active", null: false

      t.timestamps
    end
    add_index :users, :email_address, unique: true
    add_index :users, :name, unique: true
  end
end
