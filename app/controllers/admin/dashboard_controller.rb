module Admin
  class DashboardController < ApplicationController
    def index
      authorize :user, :index?
      @sandboxes = Sandbox.active.includes(:user, :routes).order(:name)
      @users = User.includes(:sandboxes).order(:name)
    end

    def system_status
      authorize :user, :index?
      @system_status = SystemStatus.new.call
      render partial: "system_status"
    end
  end
end
