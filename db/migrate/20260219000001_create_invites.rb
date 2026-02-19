class CreateInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :invites do |t|
      t.string :email, null: false
      t.string :token, null: false
      t.text :message
      t.references :invited_by, null: false, foreign_key: { to_table: :users }
      t.datetime :accepted_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :invites, :token, unique: true
    add_index :invites, :email
  end
end
