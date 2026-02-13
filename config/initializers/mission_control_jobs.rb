# Configure Mission Control Jobs for admin access
Rails.application.configure do
  # Disable HTTP Basic auth (we use session-based auth instead)
  config.mission_control.jobs.http_basic_auth_enabled = false

  # Authenticate admin users for Mission Control Jobs
  config.to_prepare do
    MissionControl::Jobs::ApplicationController.class_eval do
      include Authentication
      before_action :require_authentication!
      before_action :require_admin!

      private

      def require_admin!
        unless Current.user&.admin?
          redirect_to root_path, alert: "Access denied. Admin privileges required."
        end
      end
    end
  end
end
