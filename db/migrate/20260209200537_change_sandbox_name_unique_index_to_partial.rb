class ChangeSandboxNameUniqueIndexToPartial < ActiveRecord::Migration[8.1]
  def up
    remove_index :sandboxes, [:user_id, :name]
    add_index :sandboxes, [:user_id, :name], unique: true, where: "status != 'destroyed'"
  end

  def down
    remove_index :sandboxes, [:user_id, :name]
    add_index :sandboxes, [:user_id, :name], unique: true
  end
end
