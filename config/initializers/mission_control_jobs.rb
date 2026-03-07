MissionControl::Jobs.base_controller_class = "Admin::BaseController"
MissionControl::Jobs.http_basic_auth_enabled = false

Rails.application.config.after_initialize do
  MissionControl::Jobs::ApplicationController.layout "admin"
end
