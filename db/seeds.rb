admin = User.find_or_create_by!(email_address: "admin@sandcastle.rocks") do |u|
  u.name = "admin"
  u.password = "sandcastle"
  u.password_confirmation = "sandcastle"
  u.admin = true
  u.ssh_public_key = "ssh-ed25519 PLACEHOLDER replace-with-real-key"
end

puts "Admin user created: #{admin.email_address} (password: sandcastle)"
