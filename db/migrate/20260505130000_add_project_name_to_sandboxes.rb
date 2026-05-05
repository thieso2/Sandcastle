class AddProjectNameToSandboxes < ActiveRecord::Migration[8.0]
  def change
    add_column :sandboxes, :project_name, :string
  end
end
