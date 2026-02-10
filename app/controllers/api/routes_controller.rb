module Api
  class RoutesController < BaseController
    before_action :set_sandbox

    def show
      if @sandbox.routed?
        render json: route_json(@sandbox)
      else
        render json: { error: "No route configured" }, status: :not_found
      end
    end

    def create
      RouteManager.new.add_route(
        sandbox: @sandbox,
        domain: params.require(:domain),
        port: params.fetch(:port, 8080).to_i
      )
      render json: route_json(@sandbox.reload), status: :created
    end

    def destroy
      RouteManager.new.remove_route(sandbox: @sandbox)
      render json: { status: "removed" }
    end

    private

    def set_sandbox
      @sandbox = current_user.sandboxes.active.find(params[:sandbox_id])
    end

    def route_json(sandbox)
      {
        sandbox_id: sandbox.id,
        sandbox_name: sandbox.name,
        domain: sandbox.route_domain,
        port: sandbox.route_port,
        url: sandbox.route_url
      }
    end
  end
end
