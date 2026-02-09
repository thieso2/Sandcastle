class DashboardController < ApplicationController
  def index
    @sandboxes = Current.user.sandboxes.active.order(:name)
    if Current.user.admin?
      @system_status = SystemStatus.new.call
      @users = User.includes(:sandboxes).order(:name)
    end
  end
end
