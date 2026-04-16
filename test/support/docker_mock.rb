# frozen_string_literal: true

# Stateful Docker API mock for testing
# Simulates Docker container and image operations without requiring real Docker
module DockerMock
  class << self
    attr_accessor :containers, :images, :networks, :failure_mode, :exec_calls, :exec_response

    def reset!
      @containers = {}
      @images = {
        "busybox:latest" => {
          "Id" => "sha256:busybox_default",
          "RepoTags" => [ "busybox:latest" ],
          "Size" => 1_000_000,
          "Created" => 0
        }
      }
      @networks = {}
      @failure_mode = nil
      @exec_calls = []
      @exec_response = [ [], [], 0 ]
    end

    def enable!
      reset!
      setup_mocks
    end

    def inject_failure(type)
      @failure_mode = type
    end

    # Build a mock Docker object. Docker::Base.new is private and requires
    # a connection + hash with 'id'. We use send(:new) to bypass visibility.
    def build(klass, id, info = {})
      conn = Docker.connection
      obj = klass.send(:new, conn, { "id" => id }.merge(info))
      obj.instance_variable_set(:@info, info)
      obj
    end

    private

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
          "Ports" => {},
          "Networks" => {}
        }
      }

      DockerMock.containers[container_id] = container_data
      sleep 0.1 # Simulate creation delay

      DockerMock.build(Docker::Container, container_id, container_data)
    end

    def get(id)
      raise Docker::Error::NotFoundError, "Container not found" unless DockerMock.containers.key?(id)

      container_data = DockerMock.containers[id]
      DockerMock.build(Docker::Container, id, container_data)
    end

    def all(opts = {}, _conn = nil)
      DockerMock.containers.values.map do |data|
        DockerMock.build(Docker::Container, data["Id"], data)
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

    def stop(opts = {})
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

    def wait(timeout = nil)
      { "StatusCode" => 0 }
    end

    def refresh!
      @info = DockerMock.containers[@id] if DockerMock.containers.key?(@id)
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

    def exec(cmd, opts = {})
      raise Docker::Error::DockerError, "Simulated exec failure" if DockerMock.failure_mode == :exec

      DockerMock.exec_calls << { container_id: @id, cmd: cmd }
      response = DockerMock.exec_response
      response.respond_to?(:call) ? response.call(cmd) : response
    end

    def commit(opts = {})
      image_id = "sha256:#{SecureRandom.hex(32)}"
      repo = opts[:repo] || opts["repo"] || "snapshot"
      tag = opts[:tag] || opts["tag"] || "latest"

      image_data = {
        "Id" => image_id,
        "RepoTags" => [ "#{repo}:#{tag}" ],
        "Size" => rand(100_000_000..500_000_000),
        "Created" => Time.current.to_i
      }

      DockerMock.images[image_id] = image_data

      DockerMock.build(Docker::Image, image_id, image_data)
    end
  end

  module ImageMethods
    def create(opts = {}, _creds = nil, _conn = nil)
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

      DockerMock.build(Docker::Image, image_id, image_data)
    end

    def all(opts = {})
      DockerMock.images.values.map do |data|
        DockerMock.build(Docker::Image, data["Id"], data)
      end
    end

    def get(id_or_name, _opts = {}, _conn = nil)
      image_data = DockerMock.images[id_or_name] ||
                   DockerMock.images.values.find { |img| img["RepoTags"]&.include?(id_or_name) }

      raise Docker::Error::NotFoundError, "Image not found" unless image_data

      DockerMock.build(Docker::Image, image_data["Id"], image_data)
    end
  end

  module ImageInstanceMethods
    def remove(opts = {})
      DockerMock.images.delete(@id)
      # Also remove by repo tag
      DockerMock.images.reject! { |_k, v| v["Id"] == @id }
    end

    def info
      @info || {}
    end
  end

  module NetworkMethods
    def create(name, opts = {})
      network_id = "mock_net_#{SecureRandom.hex(16)}"

      network_data = {
        "Id" => network_id,
        "Name" => name,
        "Driver" => opts["Driver"] || "bridge",
        "Labels" => opts["Labels"] || {},
        "IPAM" => opts["IPAM"] || {},
        "Containers" => {}
      }

      DockerMock.networks[network_id] = network_data

      DockerMock.build(Docker::Network, network_id, network_data)
    end

    def get(id_or_name)
      network_data = DockerMock.networks[id_or_name] ||
                     DockerMock.networks.values.find { |net| net["Name"] == id_or_name }

      raise Docker::Error::NotFoundError, "Network not found" unless network_data

      DockerMock.build(Docker::Network, network_data["Id"], network_data)
    end

    def all(opts = {})
      DockerMock.networks.values.map do |data|
        DockerMock.build(Docker::Network, data["Id"], data)
      end
    end
  end

  module NetworkInstanceMethods
    def connect(container_id, _opts = {})
      raise Docker::Error::NotFoundError, "Container not found" unless DockerMock.containers.key?(container_id)

      network_data = DockerMock.networks.values.find { |n| n["Id"] == @id }
      network_data["Containers"][container_id] = {} if network_data

      container_data = DockerMock.containers[container_id]
      if container_data
        container_data["NetworkSettings"] ||= {}
        container_data["NetworkSettings"]["Networks"] ||= {}
        container_data["NetworkSettings"]["Networks"][network_data&.dig("Name") || @id] = {}
      end
    end

    def disconnect(container_id, _opts = {})
      network_data = DockerMock.networks.values.find { |n| n["Id"] == @id }
      network_data&.dig("Containers")&.delete(container_id)

      container_data = DockerMock.containers[container_id]
      if container_data
        name = network_data&.dig("Name") || @id
        container_data.dig("NetworkSettings", "Networks")&.delete(name)
      end
    end

    def delete
      DockerMock.networks.delete(@id)
    end

    def info
      @info || {}
    end
  end
end
