# frozen_string_literal: true

# Configure MissionControl::Jobs authentication
Rails.application.configure do
  config.mission_control.jobs.base_controller_class = "Admin::BaseController"
end
