require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SessionTestHelper
  include ActiveJob::TestHelper

  if ENV["SYSTEM_TEST_DRIVER"] == "rack_test"
    driven_by :rack_test
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
  end
end
