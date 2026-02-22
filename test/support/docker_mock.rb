# frozen_string_literal: true

# Stateful Docker API mock for testing
# Simulates Docker container and image operations without requiring real Docker.
#
# State is keyed on Thread.current so parallel test threads are fully isolated —
# one thread's DockerMock.reset! never interferes with another thread's test.
module DockerMock
  class << self
    # --- thread-local accessors ---

    def containers    = thread_store[:containers]
    def images        = thread_store[:images]
    def networks      = thread_store[:networks]
    def failure_mode  = thread_store[:failure_mode]
    def failure_mode=(val)
      thread_store[:failure_mode] = val
    end

    def reset!
      Thread.current[:docker_mock_store] = { containers: {}, images: {}, networks: {}, failure_mode: nil }
    end

    def enable!
      reset!
      setup_mocks
    end

    def inject_failure(type)
      thread_store[:failure_mode] = type
    end

    private

    def thread_store
      Thread.current[:docker_mock_store] ||= { containers: {}, images: {}, networks: {}, failure_mode: nil }
    end

    def setup_mocks
      # Mock Docker::Container
      Docker::Container.singleton_class.prepend(ContainerMethods)
      Docker::Container.prepend(ContainerInstanceMethods)

      # Mock Docker::Image
      Docker::Image.singleton_class.prepend(ImageMethods)
      Docker::Image.prepend(ImageInstanceMethods)

      # Mock Docker::Network
      Docker::Network.singleton_class.prepend(NetworkMethods)
      Docker::Network.prepend(NetworkInstanceMethods)
    end
  end

  module ContainerMethods
    def create(opts)
      raise Docker::Error::DockerError, "Simulated create failure" if DockerMock.failure_mode == :create

      container_id = "mock_#{SecureRandom.hex(16)}"
      container_name = opts.dig("name") || "container_#{SecureRandom.hex(4)}"

      container_data = {
        "Id" => container_id,
        "Name" => container_name,
        "State" => {
          "Status" => "created",
          "Running" => false,
          "Pid" => 0
        },
        "Config" => opts,
        "NetworkSettings" => {
          "Ports" => {}
        }
      }

      DockerMock.containers[container_id] = container_data

      mock_container = Docker::Container.allocate
      mock_container.instance_variable_set(:@id, container_id)
      mock_container.instance_variable_set(:@info, container_data)
      mock_container
    end

    def get(id)
      raise Docker::Error::NotFoundError, "Container not found" unless DockerMock.containers.key?(id)

      container_data = DockerMock.containers[id]
      mock_container = Docker::Container.allocate
      mock_container.instance_variable_set(:@id, id)
      mock_container.instance_variable_set(:@info, container_data)
      mock_container
    end

    def all(opts = {}, _connection = nil)
      DockerMock.containers.values.map do |data|
        mock_container = Docker::Container.allocate
        mock_container.instance_variable_set(:@id, data["Id"])
        mock_container.instance_variable_set(:@info, data)
        mock_container
      end
    end
  end

  module ContainerInstanceMethods
    def start
      raise Docker::Error::DockerError, "Simulated start failure" if DockerMock.failure_mode == :start

      container_data = DockerMock.containers[@id]
      return unless container_data

      container_data["State"]["Status"] = "running"
      container_data["State"]["Running"] = true
      container_data["State"]["Pid"] = rand(1000..9999)

      self
    end

    def stop(opts = {})
      raise Docker::Error::DockerError, "Simulated stop failure" if DockerMock.failure_mode == :stop

      container_data = DockerMock.containers[@id]
      return unless container_data

      container_data["State"]["Status"] = "exited"
      container_data["State"]["Running"] = false
      container_data["State"]["Pid"] = 0

      self
    end

    def delete(opts = {})
      raise Docker::Error::DockerError, "Simulated delete failure" if DockerMock.failure_mode == :delete

      DockerMock.containers.delete(@id)
      self
    end

    def stats(opts = {})
      {
        "cpu_stats" => {
          "cpu_usage" => {
            "total_usage" => rand(1_000_000_000..5_000_000_000)
          },
          "system_cpu_usage" => rand(10_000_000_000..50_000_000_000),
          "online_cpus" => 4
        },
        "precpu_stats" => {
          "cpu_usage" => {
            "total_usage" => rand(1_000_000_000..5_000_000_000)
          },
          "system_cpu_usage" => rand(10_000_000_000..50_000_000_000)
        },
        "memory_stats" => {
          "usage" => rand(100_000_000..500_000_000), # ~100-500 MB
          "limit" => 2_147_483_648 # 2 GB
        },
        "networks" => {
          "eth0" => {
            "rx_bytes" => rand(1_000_000..10_000_000),
            "tx_bytes" => rand(1_000_000..10_000_000)
          }
        },
        "blkio_stats" => {
          "io_service_bytes_recursive" => [
            { "op" => "Read", "value" => rand(1_000_000..10_000_000) },
            { "op" => "Write", "value" => rand(1_000_000..10_000_000) }
          ]
        },
        "pids_stats" => {
          "current" => rand(10..50)
        }
      }
    end

    def exec(cmd, opts = {})
      # No-op by default; tests that need to inspect exec calls should stub this.
      [ [], [], 0 ]
    end

    def refresh!
      # Re-read latest state from DockerMock store
      if (data = DockerMock.containers[@id])
        @info = data
      end
      self
    end

    def json
      @info || DockerMock.containers[@id] || {}
    end

    def id
      @id
    end

    def info
      json
    end

    def commit(opts = {})
      opts = opts.transform_keys(&:to_s)
      image_id = "sha256:#{SecureRandom.hex(32)}"
      repo = opts["repo"] || "snapshot"
      tag = opts["tag"] || "latest"

      image_data = {
        "Id" => image_id,
        "RepoTags" => [ "#{repo}:#{tag}" ],
        "Size" => rand(100_000_000..500_000_000),
        "Created" => Time.current.to_i
      }

      DockerMock.images[image_id] = image_data

      mock_image = Docker::Image.allocate
      mock_image.instance_variable_set(:@id, image_id)
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
    end
  end

  module ImageInstanceMethods
    def remove(opts = {})
      raise Docker::Error::DockerError, "Simulated remove failure" if DockerMock.failure_mode == :remove

      DockerMock.images.delete(@id)
      # Also remove by tag
      DockerMock.images.delete_if { |_k, v| v["RepoTags"]&.include?(@id) }
      self
    end

    def id
      @id
    end

    def info
      @info || DockerMock.images[@id] || {}
    end
  end

  module ImageMethods
    def create(opts)
      raise Docker::Error::DockerError, "Simulated pull failure" if DockerMock.failure_mode == :pull

      from_image = opts["fromImage"] || "library/ubuntu:latest"
      image_id = "sha256:#{SecureRandom.hex(32)}"

      image_data = {
        "Id" => image_id,
        "RepoTags" => [ from_image ],
        "Size" => rand(100_000_000..500_000_000),
        "Created" => Time.current.to_i
      }

      DockerMock.images[image_id] = image_data

      mock_image = Docker::Image.allocate
      mock_image.instance_variable_set(:@id, image_id)
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
    end

    def all(opts = {})
      DockerMock.images.values.map do |data|
        mock_image = Docker::Image.allocate
        mock_image.instance_variable_set(:@id, data["Id"])
        mock_image.instance_variable_set(:@info, data)
        mock_image
      end
    end

    def get(id_or_name)
      image_data = DockerMock.images[id_or_name] ||
                   DockerMock.images.values.find { |img| img["RepoTags"]&.include?(id_or_name) }

      raise Docker::Error::NotFoundError, "Image not found" unless image_data

      mock_image = Docker::Image.allocate
      mock_image.instance_variable_set(:@id, image_data["Id"])
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
    end
  end

  module NetworkInstanceMethods
    def connect(container_id, opts = {}, body_opts = {})
      network_data = DockerMock.networks[@id]
      return unless network_data

      network_data["Containers"] ||= {}
      network_data["Containers"][container_id] = {}
    end

    def disconnect(container_id, opts = {})
      network_data = DockerMock.networks[@id]
      return unless network_data

      network_data["Containers"]&.delete(container_id)
    end

    def id
      @id
    end

    def info
      @info || DockerMock.networks[@id] || {}
    end
  end

  module NetworkMethods
    def create(name, opts = {})
      network_id = "mock_net_#{SecureRandom.hex(16)}"

      network_data = {
        "Id" => network_id,
        "Name" => name,
        "Driver" => opts["Driver"] || "bridge",
        "IPAM" => opts["IPAM"] || {},
        "Containers" => {}
      }

      DockerMock.networks[network_id] = network_data

      mock_network = Docker::Network.allocate
      mock_network.instance_variable_set(:@id, network_id)
      mock_network.instance_variable_set(:@info, network_data)
      mock_network
    end

    def get(id_or_name)
      network_data = DockerMock.networks[id_or_name] ||
                     DockerMock.networks.values.find { |net| net["Name"] == id_or_name }

      raise Docker::Error::NotFoundError, "Network not found" unless network_data

      mock_network = Docker::Network.allocate
      mock_network.instance_variable_set(:@id, network_data["Id"])
      mock_network.instance_variable_set(:@info, network_data)
      mock_network
    end

    def all(opts = {})
      DockerMock.networks.values.map do |data|
        mock_network = Docker::Network.allocate
        mock_network.instance_variable_set(:@id, data["Id"])
        mock_network.instance_variable_set(:@info, data)
        mock_network
      end
    end
  end
end
