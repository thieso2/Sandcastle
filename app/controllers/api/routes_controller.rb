module Api
  class RoutesController < BaseController
    before_action :set_sandbox

    def index
      render json: @sandbox.routes.map { |r| route_json(r) }
    end

    def create
      route = RouteManager.new.add_route(
        sandbox: @sandbox,
        domain: params.require(:domain),
        port: params.fetch(:port, 8080).to_i
      )
      render json: route_json(route), status: :created
    end

    def destroy
      route = @sandbox.routes.find_by!(domain: params[:domain])
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
        url: route.url
      }
    end
  end
end
