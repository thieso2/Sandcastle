module Api
  class DnsController < BaseController
    def status
      render json: DnsManager.new.status(user: current_user)
    end

    def reconcile
      manager = DnsManager.new
      manager.publish(user: current_user)
      manager.ensure_resolver(user: current_user)
      render json: manager.status(user: current_user)
    end
  end
end
