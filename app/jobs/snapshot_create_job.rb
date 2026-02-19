class SnapshotCreateJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:, name:, label: nil, layers: nil, data_subdir: nil)
    sandbox = Sandbox.find(sandbox_id)

    sandbox.start_job("snapshotting")

    SandboxManager.new.create_snapshot(
      sandbox: sandbox,
      name: name,
      label: label,
      layers: layers,
      data_subdir: data_subdir
    )

    sandbox.finish_job

  rescue => e
    Rails.logger.error("SnapshotCreateJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
    sandbox.fail_job("Snapshot failed: #{e.message}")
    raise
  end
end
