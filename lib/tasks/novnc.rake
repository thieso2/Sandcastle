namespace :novnc do
  # Pin to a specific noVNC release for reproducible builds.
  # Update this version when noVNC releases a new stable version.
  NOVNC_VERSION = "1.5.0"

  # Files/directories to copy from the noVNC release into public/novnc/
  NOVNC_ASSETS = %w[vnc.html core app vendor].freeze

  desc "Download noVNC #{NOVNC_VERSION} static files into public/novnc/ (run during Docker build and dev setup)"
  task :download do
    require "tmpdir"
    require "net/http"

    novnc_dir = File.expand_path("../../public/novnc", __dir__)
    version_file = File.join(novnc_dir, ".novnc-version")
    if File.exist?(File.join(novnc_dir, "vnc.html")) && File.exist?(version_file) && File.read(version_file).strip == NOVNC_VERSION
      puts "noVNC #{NOVNC_VERSION} already installed at #{novnc_dir}"
      next
    end
    tarball_url = "https://github.com/novnc/noVNC/archive/refs/tags/v#{NOVNC_VERSION}.tar.gz"
    puts "Downloading noVNC #{NOVNC_VERSION}..."

    Dir.mktmpdir do |tmpdir|
      tarball = File.join(tmpdir, "novnc.tar.gz")

      uri = URI(tarball_url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.get(uri.request_uri)
      end

      # Follow redirects (GitHub releases redirect to CDN)
      if response.is_a?(Net::HTTPRedirection)
        redirect_uri = URI(response["location"])
        response = Net::HTTP.start(redirect_uri.host, redirect_uri.port, use_ssl: true) do |http|
          http.get(redirect_uri.request_uri)
        end
      end

      raise "HTTP #{response.code} fetching #{tarball_url}" unless response.is_a?(Net::HTTPSuccess)

      File.write(tarball, response.body, mode: "wb")

      system("tar", "-xzf", tarball, "-C", tmpdir) or raise "tar failed"

      extracted = Dir.glob(File.join(tmpdir, "noVNC-*/")).first
      raise "Could not find extracted noVNC directory in #{tmpdir}" unless extracted

      FileUtils.mkdir_p(novnc_dir)

      NOVNC_ASSETS.each do |asset|
        src = File.join(extracted, asset)
        next unless File.exist?(src)

        dst = File.join(novnc_dir, asset)
        FileUtils.rm_rf(dst)
        FileUtils.cp_r(src, dst)
        puts "  copied #{asset}"
      end

      File.write(File.join(novnc_dir, ".novnc-version"), NOVNC_VERSION)
      puts "noVNC #{NOVNC_VERSION} installed to #{novnc_dir}"
    end
  end
end
