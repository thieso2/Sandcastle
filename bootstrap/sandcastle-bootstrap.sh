#!/bin/bash
# Sandcastle server bootstrap script
# Tested on Ubuntu 24.04 (Hetzner root server)
set -euo pipefail

echo "=== Sandcastle Server Bootstrap ==="

# 1. Install Docker (for Kamal deployment of the Rails app only)
if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    # Docker + Incus coexistence: prevent Docker from dropping forwarded packets
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        echo '{"ip-forward-no-drop": true}' > /etc/docker/daemon.json
    elif ! grep -q "ip-forward-no-drop" /etc/docker/daemon.json; then
        # Merge into existing config
        tmp=$(mktemp)
        jq '. + {"ip-forward-no-drop": true}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
    fi
    systemctl restart docker
else
    echo "Docker already installed."
fi

# 2. Install Incus + ZFS
if ! command -v incus &>/dev/null; then
    echo "Installing Incus..."
    # Add Zabbly repository for latest Incus
    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
    cat > /etc/apt/sources.list.d/zabbly-incus-stable.list << 'REPO'
deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo ${VERSION_CODENAME}) main
REPO
    apt-get update
    apt-get install -y incus zfsutils-linux
else
    echo "Incus already installed."
fi

# 3. Create ZFS pool if not exists
if ! zpool list sandcastle &>/dev/null; then
    echo "Creating ZFS pool..."
    # Use a file-backed pool for simplicity; replace with real device for production
    POOL_FILE="/var/lib/incus/disks/sandcastle.img"
    if [ ! -f "$POOL_FILE" ]; then
        mkdir -p /var/lib/incus/disks
        truncate -s 100G "$POOL_FILE"
    fi
    zpool create sandcastle "$POOL_FILE"
else
    echo "ZFS pool 'sandcastle' already exists."
fi

# 4. Initialize Incus with preseed
if ! incus profile show sandcastle &>/dev/null 2>&1; then
    echo "Initializing Incus..."
    cat <<'PRESEED' | incus admin init --preseed
config: {}
networks:
  - config:
      ipv4.address: auto
      ipv6.address: none
    description: ""
    name: incusbr0
    type: bridge
storage_pools:
  - config:
      source: sandcastle
    description: ""
    name: default
    driver: zfs
profiles:
  - config: {}
    description: Default Incus profile
    devices:
      eth0:
        name: eth0
        network: incusbr0
        type: nic
      root:
        path: /
        pool: default
        type: disk
    name: default
PRESEED

    # Create sandcastle profile
    echo "Creating sandcastle profile..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/../images/sandbox/sandcastle-profile.yaml" ]; then
        incus profile create sandcastle 2>/dev/null || true
        cat "$SCRIPT_DIR/../images/sandbox/sandcastle-profile.yaml" | incus profile edit sandcastle
    elif [ -f "/opt/sandcastle/images/sandbox/sandcastle-profile.yaml" ]; then
        incus profile create sandcastle 2>/dev/null || true
        cat /opt/sandcastle/images/sandbox/sandcastle-profile.yaml | incus profile edit sandcastle
    fi
else
    echo "Incus already initialized."
fi

# 5. Install Caddy
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

# 6. Configure UFW
echo "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp       # SSH (host)
ufw allow 80/tcp       # HTTP (redirect)
ufw allow 443/tcp      # HTTPS (Caddy)
ufw allow 2201:2299/tcp # Sandbox SSH ports
ufw --force enable

# 7. Create data directories
echo "Creating data directories..."
mkdir -p /data/users
mkdir -p /data/sandboxes
chown 1000:1000 /data/users /data/sandboxes

# 8. Write Caddyfile (replace DOMAIN with your actual domain)
DOMAIN="${SANDCASTLE_HOST:-sandcastle.rocks}"
cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    reverse_proxy localhost:3000
}
EOF
systemctl restart caddy

# 9. Build Incus images
echo "Building sandbox images..."
if [ -d "/opt/sandcastle/images/sandbox" ]; then
    bash /opt/sandcastle/images/sandbox/build-image.sh
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/../images/sandbox/build-image.sh" ]; then
        bash "$SCRIPT_DIR/../images/sandbox/build-image.sh"
    else
        echo "WARNING: Sandbox build script not found."
        echo "Clone the repo to /opt/sandcastle and re-run, or build manually."
    fi
fi

echo "Building Tailscale sidecar image..."
if [ -d "/opt/sandcastle/images/tailscale" ]; then
    bash /opt/sandcastle/images/tailscale/build-image.sh
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/../images/tailscale/build-image.sh" ]; then
        bash "$SCRIPT_DIR/../images/tailscale/build-image.sh"
    else
        echo "WARNING: Tailscale build script not found."
    fi
fi

echo ""
echo "=== Bootstrap complete ==="
echo "Next steps:"
echo "  1. Set SANDCASTLE_HOST in .env"
echo "  2. Generate SECRET_KEY_BASE: bin/rails secret"
echo "  3. docker compose up -d (Rails app via Docker)"
echo "  4. docker compose exec web bin/rails db:seed"
echo "  5. Verify: incus image list"
