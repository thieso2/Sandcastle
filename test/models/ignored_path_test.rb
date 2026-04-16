require "test_helper"

class IgnoredPathTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "valid record" do
    p = @user.ignored_paths.build(path: ".weird/file")
    assert p.valid?, p.errors.full_messages.inspect
  end

  test "uniqueness scoped to user" do
    @user.ignored_paths.create!(path: "samepath")
    assert_not @user.ignored_paths.build(path: "samepath").valid?
  end
end
