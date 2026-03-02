class AddArchiveRetentionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sandbox_archive_retention_days, :integer
  end
end
