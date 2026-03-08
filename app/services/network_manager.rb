class NetworkManager
  SHARED_NETWORK = "sandcastle-web"
  SUBNET_LOCK_KEY = 738_263_541 # arbitrary fixed key for pg_advisory_xact_lock

  class Error < StandardError; end

  # Ensure the per-user bridge network exists.
  # Creates it if missing and persists network_name + network_subnet on the user.
  # Idempotent — safe to call multiple times.
  # Uses an advisory lock to serialize subnet allocation across processes.
  def ensure_user_network(user)
    network_name = user.network_name.presence || "sc-net-#{user.name}"

    # If the stored network exists in Docker and belongs to this user, nothing to do
    if user.network_name.present? && network_owned_by?(user.network_name, user.name)
      return user
    end

    # Global advisory lock serializes subnet allocation across all users/processes
    # to prevent two concurrent calls from picking the same /24.
    User.transaction do
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{SUBNET_LOCK_KEY})")
      user.lock!
      # Re-check after acquiring lock (another process may have created it)
      user.reload
      if user.network_name.present? && network_owned_by?(user.network_name, user.name)
        return user
      end

      subnet = network_subnet_for(user)
      network_name = user.network_name.presence || "sc-net-#{user.name}"
      create_network(network_name, subnet, user)
      user.update!(network_name: network_name, network_subnet: subnet)
    end
    user
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to ensure user network for #{user.name}: #{e.message}"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    raise Error, "Failed to ensure user network for #{user.name}: #{e.message}"
  end

  # Connect a sandbox container to its owner's per-user network.
  # Calls ensure_user_network first to create the network if needed.
  def connect_sandbox(sandbox:)
    user = sandbox.user
    ensure_user_network(user)
    user.reload

    return unless sandbox.container_id.present? && user.network_name.present?

    # Check if already connected before attempting (avoids swallowing real errors)
    container = Docker::Container.get(sandbox.container_id)
    connected_networks = container.info.dig("NetworkSettings", "Networks") || {}
    return if connected_networks.key?(user.network_name)

    network = Docker::Network.get(user.network_name)
    network.connect(sandbox.container_id)
  rescue Error
    raise
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to connect sandbox #{sandbox.full_name} to user network: #{e.message}"
  end

  # Disconnect a sandbox container from its owner's per-user network.
  def disconnect_sandbox(sandbox:)
    user = sandbox.user
    return unless sandbox.container_id.present? && user.network_name.present?

    begin
      network = Docker::Network.get(user.network_name)
      network.disconnect(sandbox.container_id)
    rescue Docker::Error::NotFoundError, Docker::Error::DockerError
      # Network or container already gone — desired state reached
    end
  end

  # Remove the user's per-user network when they have no active sandboxes.
  # Active = not destroyed or archived.
  def cleanup_user_network(user)
    return if user.sandboxes.active.exists?
    return if user.network_name.blank?

    begin
      network = Docker::Network.get(user.network_name)
      owner = network.info.dig("Labels", "sandcastle.owner")
      unless owner == user.name
        Rails.logger.warn("NetworkManager: refusing to delete network #{user.network_name} — owner label mismatch (#{owner.inspect})")
        return
      end
      network.delete
    rescue Docker::Error::NotFoundError
      # Already gone
    end

    user.update!(network_name: nil, network_subnet: nil)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to cleanup user network for #{user.name}: #{e.message}"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    raise Error, "Failed to cleanup user network for #{user.name}: #{e.message}"
  end

  # Ensure a running sandbox container is connected to its user's per-user network.
  # Used by ContainerSyncJob to reconcile network membership.
  def ensure_sandbox_connected(sandbox:)
    return unless sandbox.container_id.present?

    user = sandbox.user
    ensure_user_network(user)
    user.reload

    return unless user.network_name.present?

    container = Docker::Container.get(sandbox.container_id)
    connected_networks = container.info.dig("NetworkSettings", "Networks") || {}

    unless connected_networks.key?(user.network_name)
      begin
        Docker::Network.get(user.network_name).connect(sandbox.container_id)
        Rails.logger.info("NetworkManager: reconnected #{sandbox.full_name} to #{user.network_name}")
      rescue Docker::Error::DockerError => e
        Rails.logger.warn("NetworkManager: failed to reconnect #{sandbox.full_name}: #{e.message}")
      end
    end
  rescue Docker::Error::NotFoundError
    # Container gone — ContainerSyncJob will handle this
  rescue Error => e
    Rails.logger.warn("NetworkManager: ensure_sandbox_connected failed for #{sandbox.full_name}: #{e.message}")
  end

  private

  def network_exists?(name)
    Docker::Network.get(name)
    true
  rescue Docker::Error::NotFoundError
    false
  end

  def network_owned_by?(name, expected_owner)
    network = Docker::Network.get(name)
    network.info.dig("Labels", "sandcastle.owner") == expected_owner
  rescue Docker::Error::NotFoundError
    false
  end

  def network_subnet_for(user)
    # 1. Use the subnet stored in DB — stable across Docker/reinstalls
    return user.network_subnet if user.network_subnet.present?

    # 2. If the network already exists in Docker, read its subnet
    begin
      network = Docker::Network.get("sc-net-#{user.name}")
      ipam = network.info.dig("IPAM", "Config")
      return ipam.first["Subnet"] if ipam&.first
    rescue Docker::Error::NotFoundError
      # fall through to generate a new subnet
    end

    # 3. Generate a random /24 from DOCKYARD_POOL_BASE that doesn't conflict
    generate_subnet
  end

  def generate_subnet
    base = ENV["DOCKYARD_POOL_BASE"]
    parts = if base
      base.split("/").first.split(".").map(&:to_i)
    else
      [ 10, rand(1..254), 0, 0 ]
    end

    used = existing_network_subnets

    100.times do
      parts[2] = rand(1..254)
      candidate = "#{parts[0]}.#{parts[1]}.#{parts[2]}.0/24"
      return candidate unless used.include?(candidate)
    end

    # Fallback: return last candidate (Docker will reject on collision)
    "#{parts[0]}.#{parts[1]}.#{parts[2]}.0/24"
  end

  def existing_network_subnets
    Docker::Network.all.flat_map do |network|
      (network.info.dig("IPAM", "Config") || []).filter_map { |c| c["Subnet"] }
    end
  rescue Docker::Error::DockerError
    []
  end

  def create_network(name, subnet, user)
    existing = Docker::Network.get(name)
    # Verify the existing network belongs to this user (missing label = unsafe)
    owner = existing.info.dig("Labels", "sandcastle.owner")
    unless owner == user.name
      raise Error, "Network #{name} has no owner label or belongs to another user (#{owner.inspect}), cannot reuse"
    end
    existing
  rescue Docker::Error::NotFoundError
    Docker::Network.create(
      name,
      "Driver" => "bridge",
      "Labels" => { "sandcastle.owner" => user.name },
      "IPAM" => {
        "Config" => [ { "Subnet" => subnet } ]
      }
    )
  end
end
