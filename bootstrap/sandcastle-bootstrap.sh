#!/bin/bash
# Sandcastle server bootstrap script
# Tested on Ubuntu 24.04 (Hetzner root server)
set -euo pipefail

echo "=== Sandcastle Server Bootstrap ==="

# 1. Install Docker
if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
else
    echo "Docker already installed."
fi

# 2. Install Sysbox
if ! docker info --format '{{json .Runtimes}}' | grep -q sysbox; then
    echo "Installing Sysbox..."
    SYSBOX_VERSION="0.6.6"
    ARCH=$(dpkg --print-architecture)
    wget -q "https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_${ARCH}.deb" \
        -O /tmp/sysbox.deb
    apt-get install -y /tmp/sysbox.deb
    rm /tmp/sysbox.deb
    systemctl restart docker
else
    echo "Sysbox already installed."
fi

# 3. Configure UFW
echo "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp       # SSH (host)
ufw allow 80/tcp       # HTTP (Traefik — ACME + redirect)
ufw allow 443/tcp      # HTTPS (Traefik)
ufw allow 2201:2299/tcp # Sandbox SSH ports
ufw --force enable

# 4. Create data directories
echo "Creating data directories..."
mkdir -p /data/users
mkdir -p /data/sandboxes
mkdir -p /data/traefik/dynamic

# 5. Set up Traefik configuration
DOMAIN="${SANDCASTLE_HOST:-sandcastle.rocks}"
ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"

if [ ! -f /data/traefik/traefik.yml ]; then
    echo "Writing Traefik static config..."
    cat > /data/traefik/traefik.yml << EOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /data/acme.json
      httpChallenge:
        entryPoint: web

providers:
  file:
    directory: /data/dynamic
    watch: true

log:
  level: INFO

api:
  dashboard: false
EOF
fi

# Create ACME storage with correct permissions
if [ ! -f /data/traefik/acme.json ]; then
    touch /data/traefik/acme.json
    chmod 600 /data/traefik/acme.json
fi

# Write initial Rails route config
echo "Writing Rails route config for Traefik..."
cat > /data/traefik/dynamic/rails.yml << EOF
http:
  routers:
    rails:
      rule: "Host(\`${DOMAIN}\`)"
      service: rails
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
  services:
    rails:
      loadBalancer:
        servers:
          - url: "http://sandcastle-web:80"
EOF

# 6. Create sandcastle-web Docker network
if ! docker network inspect sandcastle-web &>/dev/null; then
    echo "Creating sandcastle-web Docker network..."
    docker network create sandcastle-web
else
    echo "sandcastle-web network already exists."
fi

# 7. Build sandbox image
echo "Building sandbox image..."
if [ -d "/opt/sandcastle/images/sandbox" ]; then
    docker build -t sandcastle-sandbox:latest /opt/sandcastle/images/sandbox/
else
    echo "WARNING: Sandbox image directory not found at /opt/sandcastle/images/sandbox"
    echo "Clone the repo to /opt/sandcastle and re-run, or build manually."
fi

echo ""
echo "=== Bootstrap complete ==="
echo "Next steps:"
echo "  1. Set SANDCASTLE_HOST and ACME_EMAIL in .env"
echo "  2. Generate SECRET_KEY_BASE: bin/rails secret"
echo "  3. docker compose up -d"
echo "  4. docker compose exec web bin/rails db:seed"
