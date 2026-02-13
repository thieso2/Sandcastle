email = ENV.fetch("SANDCASTLE_ADMIN_EMAIL", "admin@sandcastle.rocks")
password = ENV.fetch("SANDCASTLE_ADMIN_PASSWORD", "sandcastle")
username = ENV.fetch("SANDCASTLE_ADMIN_USER", email.split("@").first.gsub(/[^a-z0-9_-]/i, "").downcase)

admin = User.find_or_create_by!(email_address: email) do |u|
  u.name = username
  u.password = password
  u.password_confirmation = password
  u.admin = true
  u.ssh_public_key = ENV.fetch("SANDCASTLE_ADMIN_SSH_KEY", "")
  u.must_change_password = true
end

puts "Admin user created: #{admin.email_address}"
