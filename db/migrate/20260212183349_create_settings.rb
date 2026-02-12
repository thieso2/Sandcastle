class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      # OAuth
      t.string :github_client_id
      t.text   :github_client_secret
      t.string :google_client_id
      t.text   :google_client_secret
      # SMTP
      t.string  :smtp_address
      t.integer :smtp_port, default: 587
      t.string  :smtp_username
      t.text    :smtp_password
      t.string  :smtp_authentication, default: "plain"
      t.boolean :smtp_starttls, default: true
      t.string  :smtp_from_address
      t.timestamps
    end
  end
end
