class DashboardController < ApplicationController
  def index
    if Current.user.admin?
      @sandboxes = Sandbox.active.includes(:user).order(:name)
      @system_status = SystemStatus.new.call
      @users = User.includes(:sandboxes).order(:name)
    else
      @sandboxes = Current.user.sandboxes.active.order(:name)
    end
  end

  def stats
    sandbox = if Current.user.admin?
      Sandbox.active.find(params[:id])
    else
      Current.user.sandboxes.active.find(params[:id])
    end

    if sandbox.status == "running" && sandbox.container_id.present?
      state = IncusClient.new.get_instance_state(sandbox.container_id)
      memory = state.dig("memory", "usage") || 0
      memory_limit = state.dig("memory", "limit") || 0
      @stats = {
        memory_mb: memory / 1_048_576.0,
        memory_limit_mb: memory_limit / 1_048_576.0
      }
    end

    render partial: "sandbox_stats", locals: { stats: @stats, sandbox: sandbox }
  rescue IncusClient::Error
    render partial: "sandbox_stats", locals: { stats: nil, sandbox: sandbox }
  end
end
