email = ENV.fetch("SANDCASTLE_ADMIN_EMAIL", "admin@sandcastle.rocks")
password = ENV.fetch("SANDCASTLE_ADMIN_PASSWORD", "sandcastle")

admin = User.find_or_create_by!(email_address: email) do |u|
  u.name = email.split("@").first.gsub(/[^a-z0-9_-]/i, "").downcase
  u.password = password
  u.password_confirmation = password
  u.admin = true
  u.ssh_public_key = ENV.fetch("SANDCASTLE_ADMIN_SSH_KEY", "")
end

puts "Admin user created: #{admin.email_address}"
