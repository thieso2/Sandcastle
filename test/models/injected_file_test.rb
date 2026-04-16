require "test_helper"

class InjectedFileTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "valid record" do
    f = @user.injected_files.build(path: ".npmrc", content: "//registry.npmjs.org/:_authToken=secret")
    assert f.valid?, f.errors.full_messages.inspect
  end

  test "default mode is 0600" do
    f = @user.injected_files.create!(path: ".npmrc", content: "x")
    assert_equal 0o600, f.mode
  end

  test "rejects absolute path" do
    f = @user.injected_files.build(path: "/etc/passwd", content: "x")
    assert_not f.valid?
    assert_includes f.errors[:path].to_s, "relative"
  end

  test "rejects path with .. segment" do
    f = @user.injected_files.build(path: "../etc/shadow", content: "x")
    assert_not f.valid?
  end

  test "rejects path with . segment" do
    f = @user.injected_files.build(path: "./foo", content: "x")
    assert_not f.valid?
  end

  test "rejects empty path segments" do
    f = @user.injected_files.build(path: "foo//bar", content: "x")
    assert_not f.valid?
  end

  test "uniqueness scoped to user" do
    @user.injected_files.create!(path: ".same", content: "a")
    dup = @user.injected_files.build(path: ".same", content: "b")
    assert_not dup.valid?
    assert_includes dup.errors[:path].to_s, "taken"
  end

  test "different users can have same path" do
    @user.injected_files.create!(path: ".shared", content: "a")
    other = users(:two).injected_files.build(path: ".shared", content: "b")
    assert other.valid?, other.errors.full_messages.inspect
  end

  test "content is encrypted at rest" do
    plain = "ANTHROPIC_OAUTH_REFRESH_TOKEN=very-secret"
    rec = @user.injected_files.create!(path: ".secrets", content: plain)
    raw = ActiveRecord::Base.connection.select_value("SELECT content FROM injected_files WHERE id = #{rec.id}")
    assert_not_includes raw.to_s, "very-secret"
    assert_equal plain, rec.reload.content
  end

  test "mode out of range is rejected" do
    f = @user.injected_files.build(path: ".x", content: "x", mode: 0o7777)
    assert_not f.valid?
  end
end
