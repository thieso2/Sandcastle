class AddImageTrackingToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :image_id, :string
    add_column :sandboxes, :image_built_at, :datetime
  end
end
