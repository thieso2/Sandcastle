# Configure Mission Control Jobs for admin access
Rails.application.configure do
  # Authenticate admin users for Mission Control Jobs
  config.to_prepare do
    MissionControl::Jobs::ApplicationController.class_eval do
      # Skip HTTP Basic auth filter (we use session-based auth instead)
      skip_before_action :authenticate_by_http_basic, raise: false

      include Authentication
      before_action :require_authentication
      before_action :require_admin

      private

      def require_admin
        unless Current.user&.admin?
          redirect_to root_path, alert: "Access denied. Admin privileges required."
        end
      end
    end
  end
end
