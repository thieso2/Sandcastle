class ChangeSshPortUniqueIndexToPartial < ActiveRecord::Migration[8.1]
  def up
    remove_index :sandboxes, :ssh_port
    add_index :sandboxes, :ssh_port, unique: true, where: "status != 'destroyed'"
  end

  def down
    remove_index :sandboxes, :ssh_port
    add_index :sandboxes, :ssh_port, unique: true
  end
end
