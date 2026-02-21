# Configure SolidErrors to use session-based authentication (no HTTP Basic Auth needed)
Rails.application.configure do
  config.to_prepare do
    SolidErrors::ApplicationController.class_eval do
      # Skip HTTP Basic auth filter (we use session-based auth instead)
      skip_before_action :authenticate, raise: false

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
