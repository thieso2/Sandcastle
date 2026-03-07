SolidErrors.base_controller_class = "Admin::BaseController"

Rails.application.config.after_initialize do
  SolidErrors::ApplicationController.layout "admin"
end
