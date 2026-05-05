class SandboxMountBuilder
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  def initialize(user:, sandbox:)
    @user = user
    @sandbox = sandbox
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
        source_path: home_path
      }
    end

    if @sandbox.data_path.present?
      data_path = "#{DATA_DIR}/users/#{@user.name}/data/#{@sandbox.data_path}".chomp("/")
      records << {
        mount_type: "data",
        logical_path: @sandbox.data_path,
        target_path: "/persisted",
        master_path: data_path,
        source_path: data_path
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
          source_path: path
        }
      end
    end

    records
  end
end
