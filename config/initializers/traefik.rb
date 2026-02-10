Rails.application.config.after_initialize do
  if Rails.env.production?
    host = ENV["SANDCASTLE_HOST"]
    if host.present?
      RouteManager.new.write_rails_config(host: host)
      Rails.logger.info("Traefik: wrote Rails route config for #{host}")
    end
  end
end
