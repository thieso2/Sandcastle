require "shellwords"

class BtrfsHelper
  class Error < StandardError; end

  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  class << self
    # Create a read-only snapshot of a subvolume
    # source_path: source subvolume (e.g. /data/users/alice/home)
    # snapshot_path: destination (e.g. /data/snapshots/alice/mysnap/home)
    def snapshot_subvolume(source_path, snapshot_path)
      return false unless btrfs?
      return false unless Dir.exist?(source_path)

      parent = File.dirname(snapshot_path)
      FileUtils.mkdir_p(parent) unless Dir.exist?(parent)

      output, status = run_sudo_command("/usr/bin/btrfs subvolume snapshot -r #{sh(source_path)} #{sh(snapshot_path)}")
      unless status&.success?
        raise Error, "Failed to create BTRFS snapshot #{snapshot_path}: #{output}"
      end

      Rails.logger.info("Created BTRFS snapshot: #{source_path} → #{snapshot_path}")
      true
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Snapshot failed: #{e.message}"
    end

    # Delete a snapshot subvolume
    def delete_snapshot(snapshot_path)
      return false unless Dir.exist?(snapshot_path)

      output, status = run_sudo_command("/usr/bin/btrfs subvolume delete #{sh(snapshot_path)}")
      unless status&.success?
        raise Error, "Failed to delete BTRFS snapshot #{snapshot_path}: #{output}"
      end

      Rails.logger.info("Deleted BTRFS snapshot: #{snapshot_path}")
      true
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Snapshot deletion failed: #{e.message}"
    end

    # Get the size in bytes of a subvolume (approximate, from exclusive bytes used)
    def subvolume_size(path)
      return 0 unless Dir.exist?(path)

      output, status = run_sudo_command("/usr/bin/btrfs subvolume show #{sh(path)}")
      return 0 unless status&.success?

      # Try to parse "Exclusive referenced:" from output
      if (match = output.match(/Exclusive referenced:\s+([\d.]+)\s*(\w+)/i))
        value = match[1].to_f
        unit  = match[2].downcase
        case unit
        when "kib" then (value * 1024).to_i
        when "mib" then (value * 1024 * 1024).to_i
        when "gib" then (value * 1024 * 1024 * 1024).to_i
        when "tib" then (value * 1024 * 1024 * 1024 * 1024).to_i
        else value.to_i
        end
      else
        0
      end
    rescue StandardError
      0
    end

    # Restore: create a writable subvolume from a read-only snapshot
    # snapshot_path: read-only snapshot source
    # target_path: where to create the writable copy (must not exist)
    def restore_subvolume(snapshot_path, target_path)
      return false unless btrfs?
      return false unless Dir.exist?(snapshot_path)

      # Remove target if it exists so we can restore cleanly
      if Dir.exist?(target_path)
        if subvolume?(target_path)
          delete_snapshot(target_path)
        else
          FileUtils.rm_rf(target_path)
        end
      end

      parent = File.dirname(target_path)
      FileUtils.mkdir_p(parent) unless Dir.exist?(parent)

      output, status = run_sudo_command("/usr/bin/btrfs subvolume snapshot #{sh(snapshot_path)} #{sh(target_path)}")
      unless status&.success?
        raise Error, "Failed to restore BTRFS snapshot to #{target_path}: #{output}"
      end

      ensure_owned(target_path)
      Rails.logger.info("Restored BTRFS snapshot: #{snapshot_path} → #{target_path}")
      true
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Snapshot restore failed: #{e.message}"
    end

    # Ensure a path is a BTRFS subvolume suitable as a snapshot source.
    # If the path does not exist, create it as a subvolume. If it already
    # exists as a plain directory, fail rather than hiding that future snapshot
    # operations would not actually work.
    def ensure_subvolume!(path, description: "path")
      raise Error, "BTRFS is not available" unless btrfs?

      if subvolume?(path)
        ensure_owned(path)
        return true
      end

      if Dir.exist?(path)
        raise Error, "#{description} must be a BTRFS subvolume for snapshot storage: #{path}"
      end

      create_subvolume!(path)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Failed to ensure BTRFS subvolume #{path}: #{e.message}"
    end

    # Check if a path is on a BTRFS filesystem AND we can run sudo btrfs commands.
    # Inside containers, the bind mount preserves the BTRFS filesystem type but
    # sudo is not available, so BTRFS operations would silently fail.
    def btrfs?(path = DATA_DIR)
      return @is_btrfs if defined?(@is_btrfs)

      fs_type = `stat -f -c %T #{sh(path)} 2>/dev/null`.strip
      is_btrfs_fs = fs_type == "btrfs"
      has_sudo = is_btrfs_fs && system("/usr/bin/sudo -n /usr/bin/btrfs --version >/dev/null 2>&1")
      @is_btrfs = has_sudo == true
    rescue StandardError => e
      Rails.logger.warn("BTRFS detection failed: #{e.message}")
      @is_btrfs = false
    end

    # Ensure a user's base directory exists and is owned by the current process.
    # On BTRFS, creates a subvolume; on regular filesystems, creates a plain directory.
    # Always safe to call even if the directory already exists.
    def create_user_subvolume(username)
      user_dir = "#{DATA_DIR}/users/#{username}"

      if btrfs?
        if subvolume?(user_dir)
          Rails.logger.debug("User directory is already a BTRFS subvolume: #{user_dir}")
          ensure_owned(user_dir)
          return true
        end

        if Dir.exist?(user_dir)
          # Exists but not a subvolume (e.g. created by root during install) —
          # skip conversion but still fix ownership so Rails can write into it.
          Rails.logger.info("Fixing ownership of existing user directory: #{user_dir}")
          ensure_owned(user_dir)
          return false
        end

        create_subvolume(user_dir)
      else
        FileUtils.mkdir_p(user_dir) unless Dir.exist?(user_dir)
        ensure_owned(user_dir)
        false
      end
    end

    # Create a BTRFS subvolume for a user's data subdirectory
    def create_user_data_subvolume(username, data_path)
      # Ensure parent user directory exists and is owned
      create_user_subvolume(username)

      data_dir = "#{DATA_DIR}/users/#{username}/data/#{data_path}".chomp("/")

      if btrfs?
        if subvolume?(data_dir)
          Rails.logger.debug("Data directory is already a BTRFS subvolume: #{data_dir}")
          ensure_owned(data_dir)
          return true
        end

        if Dir.exist?(data_dir)
          Rails.logger.info("Fixing ownership of existing data directory: #{data_dir}")
          ensure_owned(data_dir)
          return false
        end

        create_subvolume(data_dir)
      else
        FileUtils.mkdir_p(data_dir) unless Dir.exist?(data_dir)
        ensure_owned(data_dir)
        false
      end
    end

    # Create a BTRFS subvolume for a user's home directory or one of its subdirs
    def create_user_home_subvolume(username, home_path = nil)
      create_user_subvolume(username)

      home_dir = if home_path.present?
        "#{DATA_DIR}/users/#{username}/home/#{home_path}".chomp("/")
      else
        "#{DATA_DIR}/users/#{username}/home"
      end

      if btrfs?
        if subvolume?(home_dir)
          Rails.logger.debug("Home directory is already a BTRFS subvolume: #{home_dir}")
          ensure_owned(home_dir)
          return true
        end

        if Dir.exist?(home_dir)
          Rails.logger.info("Fixing ownership of existing home directory: #{home_dir}")
          ensure_owned(home_dir)
          return false
        end

        create_subvolume(home_dir)
      else
        FileUtils.mkdir_p(home_dir) unless Dir.exist?(home_dir)
        ensure_owned(home_dir)
        false
      end
    end

    def create_user_persisted_subvolume(username, path)
      create_user_subvolume(username)

      persisted_dir = "#{DATA_DIR}/users/#{username}/persisted/#{path}".chomp("/")

      if btrfs?
        if subvolume?(persisted_dir)
          ensure_owned(persisted_dir)
          return true
        end

        if Dir.exist?(persisted_dir)
          ensure_owned(persisted_dir)
          return false
        end

        create_subvolume(persisted_dir)
      else
        FileUtils.mkdir_p(persisted_dir) unless Dir.exist?(persisted_dir)
        ensure_owned(persisted_dir)
        false
      end
    end

    # Check if a path is a BTRFS subvolume
    def subvolume?(path)
      return false unless Dir.exist?(path)

      result = system("/usr/bin/sudo", "-n", "/usr/bin/btrfs", "subvolume", "show", path, out: File::NULL, err: File::NULL)
      result == true
    rescue StandardError => e
      Rails.logger.warn("BTRFS subvolume check failed for #{path}: #{e.message}")
      false
    end

    private

    # Create a new BTRFS subvolume
    def create_subvolume(path)
      # Ensure parent directory exists
      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exist?(parent)

      # Create subvolume using sudo with full path
      output, status = run_sudo_command("/usr/bin/btrfs subvolume create #{sh(path)}")

      unless status.success?
        raise Error, "Failed to create BTRFS subvolume #{path}: #{output}"
      end

      ensure_owned(path)

      Rails.logger.info("Created BTRFS subvolume: #{path}")
      true
    rescue StandardError => e
      Rails.logger.error("Failed to create BTRFS subvolume #{path}: #{e.message}")
      # Fall back to regular directory
      FileUtils.mkdir_p(path) unless Dir.exist?(path)
      false
    end

    def create_subvolume!(path)
      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exist?(parent)

      output, status = run_sudo_command("/usr/bin/btrfs subvolume create #{sh(path)}")
      unless status&.success?
        raise Error, "Failed to create BTRFS subvolume #{path}: #{output}"
      end

      ensure_owned(path)
      Rails.logger.info("Created BTRFS subvolume: #{path}")
      true
    end

    # Ensure the path is owned by the current process user
    def ensure_owned(path)
      return if File.stat(path).uid == Process.uid

      run_sudo_command("/usr/bin/chown #{Process.uid}:#{Process.gid} #{sh(path)}")
    end

    # Run a command with sudo
    def run_sudo_command(command)
      full_command = "/usr/bin/sudo -n #{command}"
      output = `#{full_command} 2>&1`
      [ output, $? ]
    rescue StandardError => e
      [ e.message, nil ]
    end

    def sh(value)
      Shellwords.escape(value.to_s)
    end
  end
end
