namespace :tailscale do
  desc "Clean up old Tailscale sidecar instances, networks, and image (one-time migration)"
  task cleanup_sidecars: :environment do
    puts "=== Cleaning up old Tailscale sidecar infrastructure ==="

    # Stop and delete sidecar instances (sc-ts-*)
    instances = `incus list --format csv -c n`.lines.map(&:strip).select { |n| n.start_with?("sc-ts-") }
    instances.each do |name|
      puts "Stopping and deleting sidecar: #{name}"
      system("incus stop #{name} --force 2>/dev/null")
      system("incus delete #{name} --force")
    end

    # Delete bridge networks (sc-ts-net-*)
    networks = `incus network list --format csv`.lines.map { |l| l.split(",").first&.strip }.compact
    networks.select { |n| n.start_with?("sc-ts-net-") }.each do |name|
      puts "Deleting network: #{name}"
      system("incus network delete #{name}")
    end

    # Delete the sandcastle-tailscale image
    if system("incus image alias list --format csv | grep -q '^sandcastle-tailscale,'")
      puts "Deleting sandcastle-tailscale image..."
      system("incus image delete sandcastle-tailscale")
    else
      puts "sandcastle-tailscale image not found (already gone)"
    end

    puts "Done."
  end
end
