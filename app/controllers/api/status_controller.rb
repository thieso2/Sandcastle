module Api
  class StatusController < BaseController
    def show
      render json: SystemStatus.new.call
    end
  end
end
