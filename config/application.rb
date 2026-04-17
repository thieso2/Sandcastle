require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Sandcastle
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Don't emit `Link: …; rel=preload; as=style` HTTP headers for every
    # stylesheet_link_tag. Rails adds one per stylesheet on the page; on
    # HTTP/2 the browser already fetches the <link rel="stylesheet"> tags
    # at parse time, and HTTP/2 server push is deprecated. The extra header
    # also triggers false-positive "preloaded but not used" console warnings
    # in Chrome.
    config.action_view.preload_links_header = false

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
