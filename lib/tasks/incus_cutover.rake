namespace :incus do
  desc "Mark all active sandboxes as destroyed (user homes preserved). Run after migrating to Incus."
  task cutover: :environment do
    count = Sandbox.where.not(status: "destroyed").count
    if count.zero?
      puts "No active sandboxes to mark as destroyed."
      next
    end

    puts "Marking #{count} sandbox(es) as destroyed (container_id cleared)..."
    Sandbox.where.not(status: "destroyed").update_all(status: "destroyed", container_id: nil)
    puts "Done. User home directories at /data/users/*/home are preserved."
    puts "Users can recreate sandboxes — their home dirs will be re-mounted."
  end
end
