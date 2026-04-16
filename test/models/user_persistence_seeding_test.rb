require "test_helper"

class UserPersistenceSeedingTest < ActiveSupport::TestCase
  test "newly created user is seeded with .claude and .codex persisted paths" do
    user = User.create!(
      name: "newbie#{SecureRandom.hex(3)}",
      email_address: "newbie#{SecureRandom.hex(3)}@example.com",
      password: "password",
      status: "active"
    )

    paths = user.persisted_paths.pluck(:path).sort
    assert_equal [ ".claude", ".codex" ], paths
  end
end
