module Api
  class InfosController < BaseController
    def show
      status = SystemStatus.new
      data = status.call

      render json: {
        version: Sandcastle.version,
        rails: Rails.version,
        ruby: RUBY_VERSION,
        host: data[:host],
        sandboxes: data[:sandboxes],
        docker: data[:docker],
        users: user_counts
      }
    end

    private

    def user_counts
      { total: User.count, admins: User.where(admin: true).count }
    end
  end
end
