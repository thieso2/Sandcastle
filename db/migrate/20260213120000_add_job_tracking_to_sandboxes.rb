class AddJobTrackingToSandboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :sandboxes, :job_status, :string
    add_column :sandboxes, :job_error, :text
    add_column :sandboxes, :job_started_at, :datetime

    add_index :sandboxes, :job_status
    add_index :sandboxes, [:user_id, :job_status]
  end
end
