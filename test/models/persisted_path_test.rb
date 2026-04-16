require "test_helper"

class PersistedPathTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "valid record" do
    p = @user.persisted_paths.build(path: ".my-tool")
    assert p.valid?, p.errors.full_messages.inspect
  end

  test "rejects absolute path" do
    p = @user.persisted_paths.build(path: "/etc/foo")
    assert_not p.valid?
  end

  test "rejects path traversal" do
    assert_not @user.persisted_paths.build(path: "../escape").valid?
    assert_not @user.persisted_paths.build(path: "./here").valid?
    assert_not @user.persisted_paths.build(path: "a//b").valid?
  end

  test "normalizes trailing slash" do
    p = @user.persisted_paths.create!(path: ".claude/")
    assert_equal ".claude", p.path
  end

  test "normalizes whitespace" do
    p = @user.persisted_paths.create!(path: "  .codex  ")
    assert_equal ".codex", p.path
  end

  test "uniqueness scoped to user" do
    @user.persisted_paths.find_or_create_by!(path: ".unique-test")
    dup = @user.persisted_paths.build(path: ".unique-test")
    assert_not dup.valid?
  end
end
