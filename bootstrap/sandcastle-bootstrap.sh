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

# 3. Install Caddy
if ! command -v caddy &>/dev/null; then
    echo "Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
else
    echo "Caddy already installed."
fi

# 4. Configure UFW
echo "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp       # SSH (host)
ufw allow 80/tcp       # HTTP (redirect)
ufw allow 443/tcp      # HTTPS (Caddy)
ufw allow 2201:2299/tcp # Sandbox SSH ports
ufw --force enable

# 5. Create data directories
echo "Creating data directories..."
mkdir -p /data/users
mkdir -p /data/sandboxes

# 6. Write Caddyfile (replace DOMAIN with your actual domain)
DOMAIN="${SANDCASTLE_HOST:-sandcastle.rocks}"
cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    reverse_proxy localhost:3000
}
EOF
systemctl restart caddy

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
echo "  1. Set SANDCASTLE_HOST in .env"
echo "  2. Generate SECRET_KEY_BASE: bin/rails secret"
echo "  3. docker compose up -d"
echo "  4. docker compose exec web bin/rails db:seed"
