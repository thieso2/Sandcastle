module Admin
  class BaseController < ApplicationController
    layout "admin"
    before_action :require_authentication
    before_action :require_admin

    private

    def require_admin
      authorize :user, :index?
    end
  end
end
