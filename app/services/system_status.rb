class SystemStatus
  def call
    {
      incus: incus_info,
      sandboxes: sandbox_counts,
      resources: resource_usage
    }
  end

  private

  def incus_info
    info = incus.server_info
    env = info["environment"] || {}
    {
      version: env["server_version"],
      storage: env["storage"],
      kernel: env["kernel_version"],
      instances: count_instances
    }
  rescue IncusClient::Error => e
    { error: e.message }
  end

  def count_instances
    # Get a rough count from the instance list
    info = incus.server_info
    info.dig("environment", "instance_count") || 0
  rescue IncusClient::Error
    0
  end

  def sandbox_counts
    {
      total: Sandbox.active.count,
      running: Sandbox.running.count,
      stopped: Sandbox.active.where(status: "stopped").count,
      pending: Sandbox.where(status: "pending").count
    }
  end

  def resource_usage
    running = Sandbox.running.where.not(container_id: nil)
    return [] if running.empty?

    running.map do |sandbox|
      state = incus.get_instance_state(sandbox.container_id)
      memory = state.dig("memory", "usage") || 0
      {
        sandbox: sandbox.full_name,
        memory_mb: memory / 1_048_576.0
      }
    rescue IncusClient::NotFoundError
      { sandbox: sandbox.full_name, error: "not_found" }
    end
  end

  def incus
    @incus ||= IncusClient.new
  end
end
