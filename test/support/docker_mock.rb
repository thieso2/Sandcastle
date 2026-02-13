# frozen_string_literal: true

# Stateful Docker API mock for testing
# Simulates Docker container and image operations without requiring real Docker
module DockerMock
  class << self
    attr_accessor :containers, :images, :networks, :failure_mode

    def reset!
      @containers = {}
      @images = {}
      @networks = {}
      @failure_mode = nil
    end

    def enable!
      reset!
      setup_mocks
    end

    def inject_failure(type)
      @failure_mode = type
    end

    private

    def setup_mocks
      # Mock Docker::Container
      Docker::Container.singleton_class.prepend(ContainerMethods)
      Docker::Container.prepend(ContainerInstanceMethods)

      # Mock Docker::Image
      Docker::Image.singleton_class.prepend(ImageMethods)

      # Mock Docker::Network
      Docker::Network.singleton_class.prepend(NetworkMethods)
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
      sleep 0.1 # Simulate creation delay

      mock_container = Docker::Container.new(nil, {})
      mock_container.instance_variable_set(:@id, container_id)
      mock_container.instance_variable_set(:@info, container_data)
      mock_container
    end

    def get(id)
      raise Docker::Error::NotFoundError, "Container not found" unless DockerMock.containers.key?(id)

      container_data = DockerMock.containers[id]
      mock_container = Docker::Container.new(nil, {})
      mock_container.instance_variable_set(:@id, id)
      mock_container.instance_variable_set(:@info, container_data)
      mock_container
    end

    def all(opts = {})
      DockerMock.containers.values.map do |data|
        mock_container = Docker::Container.new(nil, {})
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

      sleep 0.5 # Simulate start delay
      self
    end

    def stop
      raise Docker::Error::DockerError, "Simulated stop failure" if DockerMock.failure_mode == :stop

      container_data = DockerMock.containers[@id]
      return unless container_data

      container_data["State"]["Status"] = "exited"
      container_data["State"]["Running"] = false
      container_data["State"]["Pid"] = 0

      sleep 0.3 # Simulate stop delay
      self
    end

    def delete(opts = {})
      raise Docker::Error::DockerError, "Simulated delete failure" if DockerMock.failure_mode == :delete

      DockerMock.containers.delete(@id)
      sleep 0.2 # Simulate delete delay
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

      mock_image = Docker::Image.new(nil, {})
      mock_image.instance_variable_set(:@id, image_id)
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
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
      sleep 1 # Simulate pull delay

      mock_image = Docker::Image.new(nil, {})
      mock_image.instance_variable_set(:@id, image_id)
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
    end

    def all(opts = {})
      DockerMock.images.values.map do |data|
        mock_image = Docker::Image.new(nil, {})
        mock_image.instance_variable_set(:@id, data["Id"])
        mock_image.instance_variable_set(:@info, data)
        mock_image
      end
    end

    def get(id_or_name)
      image_data = DockerMock.images[id_or_name] ||
                   DockerMock.images.values.find { |img| img["RepoTags"]&.include?(id_or_name) }

      raise Docker::Error::NotFoundError, "Image not found" unless image_data

      mock_image = Docker::Image.new(nil, {})
      mock_image.instance_variable_set(:@id, image_data["Id"])
      mock_image.instance_variable_set(:@info, image_data)
      mock_image
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

      mock_network = Docker::Network.new(nil, {})
      mock_network.instance_variable_set(:@id, network_id)
      mock_network.instance_variable_set(:@info, network_data)
      mock_network
    end

    def get(id_or_name)
      network_data = DockerMock.networks[id_or_name] ||
                     DockerMock.networks.values.find { |net| net["Name"] == id_or_name }

      raise Docker::Error::NotFoundError, "Network not found" unless network_data

      mock_network = Docker::Network.new(nil, {})
      mock_network.instance_variable_set(:@id, network_data["Id"])
      mock_network.instance_variable_set(:@info, network_data)
      mock_network
    end

    def all(opts = {})
      DockerMock.networks.values.map do |data|
        mock_network = Docker::Network.new(nil, {})
        mock_network.instance_variable_set(:@id, data["Id"])
        mock_network.instance_variable_set(:@info, data)
        mock_network
      end
    end
  end
end
