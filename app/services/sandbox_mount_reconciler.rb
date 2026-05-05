require "digest"
require "find"

class SandboxMountReconciler
  Change = Data.define(:mount, :path, :status, :reason)

  STATUSES = %w[
    added modified deleted conflict master_changed master_added already_applied
  ].freeze

  def initialize(sandbox)
    @sandbox = sandbox
  end

  def changes
    snapshot_mounts.flat_map { |mount| changes_for_mount(mount) }
  end

  def changed?
    changes.any? { |change| actionable?(change) || change.status == "conflict" }
  end

  def apply!(selections)
    Array(selections).each do |selection|
      mount = snapshot_mounts.find { |m| m.id.to_s == selection[:mount_id].to_s }
      next unless mount

      path = clean_path(selection[:path])
      action = selection[:action].to_s

      case action
      when "use_work"
        copy_from_work!(mount, path)
      when "delete"
        delete_from_master!(mount, path)
      when "skip", ""
        next
      else
        raise ArgumentError, "Unknown reconcile action: #{action}"
      end
    end
  end

  def discard!
    snapshot_mounts.find_each do |mount|
      delete_tree(mount.work_path)
      delete_tree(mount.base_path)
      mount.update!(state: "discarded")
    end
  end

  private

  def snapshot_mounts
    @sandbox.sandbox_mounts.where(storage_mode: "snapshot", state: "active")
  end

  def changes_for_mount(mount)
    base = entries(mount.base_path)
    work = entries(mount.work_path)
    master = entries(mount.master_path)

    (base.keys | work.keys | master.keys).sort.filter_map do |path|
      status, reason = classify(base[path], work[path], master[path])
      next if status == "unchanged"
      Change.new(mount: mount, path: path, status: status, reason: reason)
    end
  end

  def classify(base, work, master)
    if base && work && master && same?(base, work) && same?(base, master)
      [ "unchanged", nil ]
    elsif base.nil? && work && master.nil?
      [ "added", "created in sandbox" ]
    elsif base && work.nil? && same?(base, master)
      [ "deleted", "removed in sandbox" ]
    elsif base && work && same?(base, master) && !same?(base, work)
      [ "modified", "changed in sandbox" ]
    elsif base && work && same?(work, master)
      [ "already_applied", "master already matches sandbox" ]
    elsif base && work && !same?(base, work) && master && !same?(base, master)
      [ "conflict", "changed in both sandbox and master" ]
    elsif base && work.nil? && master && !same?(base, master)
      [ "conflict", "deleted in sandbox, changed in master" ]
    elsif base.nil? && work && master && !same?(work, master)
      [ "conflict", "created in sandbox and master differently" ]
    elsif base && work && !same?(base, master) && same?(base, work)
      [ "master_changed", "changed only in master" ]
    elsif base.nil? && work.nil? && master
      [ "master_added", "created only in master" ]
    else
      [ "unchanged", nil ]
    end
  end

  def actionable?(change)
    %w[added modified deleted].include?(change.status)
  end

  def entries(root)
    return {} if root.blank? || !Dir.exist?(root)

    result = {}
    Find.find(root) do |path|
      next if path == root
      rel = path.delete_prefix("#{root}/")
      next if rel.blank?
      next if File.directory?(path) && !File.symlink?(path)

      result[rel] = signature(path)
    end
    result
  end

  def signature(path)
    if File.symlink?(path)
      { type: "symlink", value: File.readlink(path) }
    elsif File.file?(path)
      { type: "file", value: Digest::SHA256.file(path).hexdigest, size: File.size(path) }
    else
      { type: "other", value: File.lstat(path).mode }
    end
  end

  def same?(left, right)
    left.present? && right.present? && left == right
  end

  def clean_path(path)
    path = path.to_s
    raise ArgumentError, "Missing path" if path.blank?
    raise ArgumentError, "Invalid path" if path.start_with?("/") || path.split("/").any? { |seg| seg.blank? || seg == ".." }

    path
  end

  def copy_from_work!(mount, path)
    source = File.join(mount.work_path, path)
    target = File.join(mount.master_path, path)
    raise ArgumentError, "Sandbox path does not exist: #{path}" unless File.exist?(source) || File.symlink?(source)

    FileUtils.mkdir_p(File.dirname(target))
    if File.symlink?(source)
      FileUtils.rm_rf(target)
      File.symlink(File.readlink(source), target)
    elsif File.file?(source)
      FileUtils.cp(source, target, preserve: true)
    else
      raise ArgumentError, "Unsupported file type: #{path}"
    end
  end

  def delete_from_master!(mount, path)
    FileUtils.rm_rf(File.join(mount.master_path, path))
  end

  def delete_tree(path)
    return if path.blank? || !Dir.exist?(path)

    if BtrfsHelper.subvolume?(path)
      BtrfsHelper.delete_snapshot(path)
    else
      FileUtils.rm_rf(path)
    end
  end
end
