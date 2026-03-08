module Admin
  class DockerController < BaseController
    INFRA_CONTAINERS = %w[
      sandcastle-web
      sandcastle-worker
      sandcastle-postgres-1
      sandcastle-traefik
    ].freeze

    def index
      authorize :user, :index?
      @containers = fetch_containers
    end

    def logs
      authorize :user, :index?
      name = params[:id]
      unless INFRA_CONTAINERS.include?(name)
        return render json: { error: "Not an infra container" }, status: :forbidden
      end

      tail = (params[:tail] || 200).to_i.clamp(1, 2000)
      container = Docker::Container.get(name)
      raw = container.logs(stdout: true, stderr: true, tail: tail, timestamps: true)
      lines = strip_docker_stream_headers(raw)
      render json: { container: name, lines: lines }
    rescue Docker::Error::NotFoundError
      render json: { error: "Container not found: #{name}" }, status: :not_found
    rescue Docker::Error::DockerError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def fetch_containers
      all = Docker::Container.all(all: true)
      INFRA_CONTAINERS.map do |name|
        c = all.find { |ct| ct.info.dig("Names")&.include?("/#{name}") }
        if c
          state = c.info["State"]
          status = c.info["Status"]
          created = Time.at(c.info["Created"]).utc
          { name: name, state: state, status: status, created: created, exists: true }
        else
          { name: name, exists: false }
        end
      end
    rescue Docker::Error::DockerError => e
      INFRA_CONTAINERS.map { |name| { name: name, exists: false, error: e.message } }
    end

    # Docker log streams have 8-byte headers per frame; strip them.
    def strip_docker_stream_headers(raw)
      raw.encode("UTF-8", invalid: :replace, undef: :replace)
         .lines
         .map { |line| line.sub(/\A[\x00-\x02].{7}/, "").rstrip }
         .reject(&:empty?)
    end
  end
end
