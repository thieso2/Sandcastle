# frozen_string_literal: true

require "test_helper"

class SnapshotTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @snap = snapshots(:alice_snap)
  end

  test "valid snapshot" do
    assert @snap.valid?
  end

  test "requires name" do
    @snap.name = nil
    assert_not @snap.valid?
  end

  test "name must be lowercase alphanumeric" do
    @snap.name = "Invalid Name"
    assert_not @snap.valid?
  end

  test "name must start with letter" do
    @snap.name = "1badname"
    assert_not @snap.valid?
  end

  test "name with hyphens and underscores is valid" do
    @snap.name = "my-snap_v2"
    assert @snap.valid?
  end

  test "name must be unique per user" do
    dup = Snapshot.new(user: @user, name: @snap.name)
    assert_not dup.valid?
    assert_includes dup.errors[:name], "has already been taken"
  end

  test "same name allowed for different users" do
    other = Snapshot.new(user: users(:two), name: @snap.name, docker_image: "sc-snap-bob:my-snapshot")
    assert other.valid?
  end

  test "layers returns container when only docker_image present" do
    @snap.home_snapshot = nil
    @snap.data_snapshot = nil
    assert_equal %w[container], @snap.layers
  end

  test "layers returns all present layers" do
    full = snapshots(:alice_btrfs_snap)
    assert_equal %w[container home data], full.layers
  end

  test "layers returns empty when no layers" do
    empty_snap = Snapshot.new(user: @user, name: "empty-snap")
    assert_equal [], empty_snap.layers
  end

  test "total_size sums all layer sizes" do
    full = snapshots(:alice_btrfs_snap)
    expected = full.docker_size + full.home_size + full.data_size
    assert_equal expected, full.total_size
  end

  test "total_size handles nil sizes" do
    @snap.docker_size = nil
    @snap.home_size = nil
    assert_equal 0, @snap.total_size
  end
end
