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

    # Create a BTRFS subvolume for a user's directory
    # This creates the parent user directory as a subvolume
    def create_user_subvolume(username)
      return false unless btrfs?

      user_dir = "#{DATA_DIR}/users/#{username}"

      # Check if already a subvolume
      if subvolume?(user_dir)
        Rails.logger.debug("User directory is already a BTRFS subvolume: #{user_dir}")
        return true
      end

      if Dir.exist?(user_dir) && !Dir.empty?(user_dir)
        # Directory already has content — skip conversion to avoid root-ownership issues
        Rails.logger.info("Skipping BTRFS subvolume conversion for existing directory: #{user_dir}")
        return false
      end

      create_subvolume(user_dir)
    end

    # Create a BTRFS subvolume for a user's data subdirectory
    def create_user_data_subvolume(username, data_path)
      return false unless btrfs?

      # Ensure parent user directory exists as subvolume
      create_user_subvolume(username)

      data_dir = "#{DATA_DIR}/users/#{username}/data/#{data_path}".chomp("/")

      # Check if already a subvolume
      if subvolume?(data_dir)
        Rails.logger.debug("Data directory is already a BTRFS subvolume: #{data_dir}")
        return true
      end

      if Dir.exist?(data_dir) && !Dir.empty?(data_dir)
        # Directory already has content — skip conversion to avoid root-ownership issues
        Rails.logger.info("Skipping BTRFS subvolume conversion for existing directory: #{data_dir}")
        return false
      end

      create_subvolume(data_dir)
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

      run_sudo_command("/usr/bin/chown #{Process.uid}:#{Process.gid} #{path}")

      Rails.logger.info("Created BTRFS subvolume: #{path}")
      true
    rescue StandardError => e
      Rails.logger.error("Failed to create BTRFS subvolume #{path}: #{e.message}")
      # Fall back to regular directory
      FileUtils.mkdir_p(path) unless Dir.exist?(path)
      false
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
