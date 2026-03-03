class AddArchiveToSandboxes < ActiveRecord::Migration[8.1]
  def up
    add_column :sandboxes, :archived_at, :datetime

    # Update partial unique indexes to also exclude archived sandboxes
    # (so users can reuse the name/port after archiving)
    remove_index :sandboxes, [ :user_id, :name ]
    add_index :sandboxes, [ :user_id, :name ], unique: true,
              where: "status NOT IN ('destroyed', 'archived')"

    remove_index :sandboxes, :ssh_port
    add_index :sandboxes, :ssh_port, unique: true,
              where: "status NOT IN ('destroyed', 'archived') AND ssh_port IS NOT NULL"
  end

  def down
    remove_column :sandboxes, :archived_at

    remove_index :sandboxes, [ :user_id, :name ]
    add_index :sandboxes, [ :user_id, :name ], unique: true,
              where: "status != 'destroyed'"

    remove_index :sandboxes, :ssh_port
    add_index :sandboxes, :ssh_port, unique: true,
              where: "status != 'destroyed'"
  end
end
