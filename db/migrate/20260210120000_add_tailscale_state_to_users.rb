class AddTailscaleStateToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tailscale_state, :string, default: "disabled", null: false

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE users SET tailscale_state = 'enabled' WHERE tailscale_enabled = 1
        SQL
      end
    end

    remove_column :users, :tailscale_enabled, :boolean, default: false, null: false
  end
end
