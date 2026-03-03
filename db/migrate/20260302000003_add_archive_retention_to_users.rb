class AddArchiveRetentionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sandbox_archive_retention_days, :integer
    add_check_constraint :users,
      "sandbox_archive_retention_days IS NULL OR sandbox_archive_retention_days >= 0",
      name: "users_sandbox_archive_retention_days_non_negative"
  end
end
