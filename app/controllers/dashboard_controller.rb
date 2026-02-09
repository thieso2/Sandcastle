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
end
