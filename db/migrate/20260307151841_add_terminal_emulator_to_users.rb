class AddTerminalEmulatorToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :terminal_emulator, :string, default: "xterm"
  end
end
