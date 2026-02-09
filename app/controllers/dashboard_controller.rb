class DashboardController < ApplicationController
  def index
    @sandboxes = Current.user.sandboxes.active.order(:name)
    @system_status = SystemStatus.new.call if Current.user.admin?
  end
end
