module Api
  class RoutesController < BaseController
    before_action :set_sandbox

    def index
      render json: @sandbox.routes.map { |r| route_json(r) }
    end

    def create
      route = RouteManager.new.add_route(
        sandbox: @sandbox,
        domain: params[:domain],
        port: params.fetch(:port, 8080).to_i,
        mode: params.fetch(:mode, "http")
      )
      render json: route_json(route), status: :created
    end

    def destroy
      route = @sandbox.routes.find(params[:id])
      RouteManager.new.remove_route(route: route)
      render json: { status: "removed" }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Route not found" }, status: :not_found
    end

    private

    def set_sandbox
      @sandbox = current_user.sandboxes.active.find(params[:sandbox_id])
    end

    def route_json(route)
      {
        id: route.id,
        sandbox_id: route.sandbox_id,
        sandbox_name: route.sandbox.name,
        domain: route.domain,
        port: route.port,
        mode: route.mode,
        public_port: route.public_port,
        url: route.url
      }
    end
  end
end
