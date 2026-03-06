class ContainerMetricsJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current

    Sandbox.running.where.not(container_id: nil).find_each do |sandbox|
      raw = Docker::Container.get(sandbox.container_id).stats(stream: false)
      next if raw.blank?

      ContainerMetric.create!(
        sandbox: sandbox,
        cpu_percent: StatsCalculator.cpu_percent(raw),
        memory_mb: StatsCalculator.memory_mb(raw),
        recorded_at: now
      )
    rescue Docker::Error::DockerError => e
      Rails.logger.warn("ContainerMetricsJob: #{sandbox.full_name}: #{e.message}")
    end

    ContainerMetric.where("recorded_at < ?", 1.hour.ago).delete_all
  end
end
