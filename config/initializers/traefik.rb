Rails.application.config.after_initialize do
  if Rails.env.production?
    host = ENV["SANDCASTLE_HOST"]
    if host.present?
      begin
        RouteManager.new.write_rails_config(host: host)
        Rails.logger.info("Traefik: wrote Rails route config for #{host}")
      rescue => e
        Rails.logger.warn("Traefik: failed to write Rails route config: #{e.message}")
      end
    end
  end
end
