class ChangeDefaultSandboxImage < ActiveRecord::Migration[8.1]
  def change
    change_column_default :sandboxes, :image, from: "sandcastle-sandbox:latest", to: "ghcr.io/thieso2/sandcastle-sandbox:latest"
  end
end
