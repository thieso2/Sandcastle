class AddSshStartTmux < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :default_ssh_start_tmux, :boolean, default: true, null: false
    add_column :sandboxes, :ssh_start_tmux, :boolean
  end
end
