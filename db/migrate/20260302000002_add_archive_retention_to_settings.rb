class AddArchiveRetentionToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :sandbox_archive_retention_days, :integer, default: 30, null: false
  end
end
