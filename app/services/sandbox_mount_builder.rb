class SandboxMountBuilder
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  def initialize(user:, sandbox:)
    @user = user
    @sandbox = sandbox
  end

  def mount_attributes
    records = direct_mount_attributes
    return records unless @sandbox.storage_mode == "snapshot"

    records.map { |attrs| snapshot_mount_attributes(attrs) }
  end

  def direct_mount_attributes
    records = []

    if @sandbox.mount_home
      home_path = "#{DATA_DIR}/users/#{@user.name}/home"
      records << {
        mount_type: "home",
        logical_path: nil,
        target_path: "/home/#{@user.name}",
        master_path: home_path,
        source_path: home_path,
        storage_mode: "direct"
      }
    end

    if @sandbox.data_path.present?
      data_path = "#{DATA_DIR}/users/#{@user.name}/data/#{@sandbox.data_path}".chomp("/")
      records << {
        mount_type: "data",
        logical_path: @sandbox.data_path,
        target_path: "/persisted",
        master_path: data_path,
        source_path: data_path,
        storage_mode: "direct"
      }
    end

    if !@sandbox.mount_home
      @user.persisted_paths.find_each do |pp|
        path = "#{DATA_DIR}/users/#{@user.name}/persisted/#{pp.path}"
        records << {
          mount_type: "persisted_path",
          logical_path: pp.path,
          target_path: "/home/#{@user.name}/#{pp.path}",
          master_path: path,
          source_path: path,
          storage_mode: "direct"
        }
      end
    end

    records
  end

  private

  def snapshot_mount_attributes(attrs)
    component = case attrs[:mount_type]
    when "home"
      "home"
    when "data"
      "data"
    else
      "persisted/#{attrs[:logical_path]}"
    end

    base_path = "#{DATA_DIR}/sandbox_mounts/#{@sandbox.id}/base/#{component}".chomp("/")
    work_path = "#{DATA_DIR}/sandbox_mounts/#{@sandbox.id}/work/#{component}".chomp("/")

    attrs.merge(
      storage_mode: "snapshot",
      source_path: work_path,
      base_path: base_path,
      work_path: work_path
    )
  end
end
