class DashboardController < ApplicationController
  def index
    @sandboxes = Current.user.sandboxes.active.order(:name)
    @system_status = SystemStatus.new.call if Current.user.admin?
    @all_users = User.includes(:sandboxes).order(:name) if Current.user.admin?
  end
end
