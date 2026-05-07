require "shellwords"
require "socket"

class PermissionRepair
  DEFAULT_IMAGES = %w[busybox:latest alpine:latest].freeze
  REPAIR_CONTAINER_ENV = "SANDCASTLE_PERMISSION_REPAIR_CONTAINER".freeze

  class Error < StandardError; end

  def self.run(host_path, *cmd)
    new.run(host_path, *cmd)
  end

  def self.chown_chmod(host_path, uid: Process.uid, gid: Process.gid, mode: nil, recursive: false)
    new.chown_chmod(host_path, uid: uid, gid: gid, mode: mode, recursive: recursive)
  end

  def self.fix_image
    new.fix_image
  end

  def run(host_path, *cmd)
    run_in_current_container(host_path, *cmd)
  rescue Docker::Error::NotFoundError
    run_in_helper_container(host_path, *cmd)
  rescue Docker::Error::DockerError, Error => current_error
    begin
      run_in_helper_container(host_path, *cmd)
    rescue Error => helper_error
      raise Error, "current-container repair failed: #{current_error.message}; helper-container repair failed: #{helper_error.message}"
    end
  end

  def chown_chmod(host_path, uid:, gid:, mode: nil, recursive: false)
    chown_flags = recursive ? "-R " : ""
    mode_arg = mode.is_a?(Integer) ? mode.to_s(8) : mode
    commands = [ "chown #{chown_flags}#{uid}:#{gid} /mnt" ]
    commands << "chmod #{mode_arg} /mnt" if mode_arg
    run(host_path, "sh", "-c", commands.join(" && "))
  end

  def fix_image
    DEFAULT_IMAGES.each do |image|
      return image if Docker::Image.get(image)
    rescue Docker::Error::DockerError
      next
    end

    image = Docker::Image.all.first
    raise Error, "no local Docker images available for permission repair" unless image

    image.info["RepoTags"]&.first || image.id
  end

  private

  def run_in_current_container(host_path, *cmd)
    container = Docker::Container.get(current_container_id)
    translated_cmd = translate_mount_args(host_path, cmd)
    _stdout, _stderr, status = container.exec(translated_cmd, user: "root")
    exit_code = exit_code_for(status)
    raise Error, "permission repair failed (exit #{exit_code}) for #{host_path}: #{translated_cmd.join(' ')}" unless exit_code == 0
  end

  def run_in_helper_container(host_path, *cmd)
    container = Docker::Container.create(
      "Image" => fix_image,
      "Cmd" => cmd,
      "HostConfig" => {
        "Binds" => [ "#{host_path}:/mnt" ],
        "NetworkMode" => "none",
        "UsernsMode" => "host"
      }
    )
    container.start
    result = container.wait(30)
    exit_code = result&.dig("StatusCode") || -1
    raise Error, "permission repair failed (exit #{exit_code}) for #{host_path}: #{cmd.join(' ')}" unless exit_code == 0
  rescue Docker::Error::DockerError => e
    raise Error, e.message
  ensure
    container&.delete(force: true) rescue nil
  end

  def current_container_id
    configured = ENV[REPAIR_CONTAINER_ENV]
    configured.nil? || configured.empty? ? Socket.gethostname : configured
  end

  def translate_mount_args(host_path, cmd)
    if cmd[0] == "sh" && cmd[1] == "-c" && cmd[2]
      [ cmd[0], cmd[1], translate_mount_shell(host_path, cmd[2]) ] + cmd.drop(3)
    else
      cmd.map { |arg| translate_mount_arg(host_path, arg) }
    end
  end

  def translate_mount_shell(host_path, script)
    escaped_path = Shellwords.escape(host_path)
    script.gsub(%r{/mnt(?=/|[^A-Za-z0-9_.-]|$)}, escaped_path)
  end

  def translate_mount_arg(host_path, arg)
    return arg unless arg.is_a?(String)
    return host_path if arg == "/mnt"
    return File.join(host_path, arg.delete_prefix("/mnt/")) if arg.start_with?("/mnt/")

    arg
  end

  def exit_code_for(status)
    return status if status.is_a?(Integer)
    return status.exitstatus if status.respond_to?(:exitstatus)
    return status["StatusCode"] if status.is_a?(Hash) && status.key?("StatusCode")

    -1
  end
end
