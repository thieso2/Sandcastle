class RoutesController < ApplicationController
  before_action :set_sandbox

  def create
    RouteManager.new.add_route(
      sandbox: @sandbox,
      domain: params.dig(:route, :domain).presence&.strip,
      port: params.require(:route).fetch(:port, 8080).to_i,
      mode: params.dig(:route, :mode).presence || "http"
    )
    redirect_to sandbox_path(@sandbox), notice: "Route added."
  rescue RouteManager::Error, ActiveRecord::RecordInvalid => e
    redirect_to sandbox_path(@sandbox), alert: e.message
  end

  def destroy
    route = @sandbox.routes.find(params[:id])
    RouteManager.new.remove_route(route: route)
    redirect_to sandbox_path(@sandbox), notice: "Route removed."
  rescue ActiveRecord::RecordNotFound
    redirect_to sandbox_path(@sandbox), alert: "Route not found."
  rescue RouteManager::Error => e
    redirect_to sandbox_path(@sandbox), alert: e.message
  end

  private

  def set_sandbox
    @sandbox = policy_scope(Sandbox).find(params[:sandbox_id])
    authorize @sandbox, :show?
  end
end
