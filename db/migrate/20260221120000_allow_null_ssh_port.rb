class AllowNullSshPort < ActiveRecord::Migration[8.1]
  def change
    change_column_null :sandboxes, :ssh_port, true
  end
end
