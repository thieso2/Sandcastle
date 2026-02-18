class BtrfsHelper
  class Error < StandardError; end

  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  class << self
    # Check if a path is on a BTRFS filesystem
    def btrfs?(path = DATA_DIR)
      return @is_btrfs if defined?(@is_btrfs)

      result = system("stat -f -c %T #{path} 2>/dev/null | grep -q '^btrfs$'")
      @is_btrfs = result == true
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

    private

    # Check if a path is a BTRFS subvolume
    def subvolume?(path)
      return false unless Dir.exist?(path)

      result = system("/usr/bin/sudo /usr/bin/btrfs subvolume show #{path} >/dev/null 2>&1")
      result == true
    rescue StandardError => e
      Rails.logger.warn("BTRFS subvolume check failed for #{path}: #{e.message}")
      false
    end

    # Create a new BTRFS subvolume
    def create_subvolume(path)
      # Ensure parent directory exists
      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exist?(parent)

      # Create subvolume using sudo with full path
      output, status = run_sudo_command("/usr/bin/btrfs subvolume create #{path}")

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

    # Ensure the path is owned by the current process user
    def ensure_owned(path)
      return if File.stat(path).uid == Process.uid

      run_sudo_command("/usr/bin/chown #{Process.uid}:#{Process.gid} #{path}")
    end

    # Run a command with sudo
    def run_sudo_command(command)
      full_command = "/usr/bin/sudo -n #{command}"
      output = `#{full_command} 2>&1`
      [ output, $? ]
    rescue StandardError => e
      [ e.message, nil ]
    end
  end
end
