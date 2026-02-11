#!/bin/bash
# Sandcastle one-line installer
# curl -fsSL https://install.sandcastle.rocks | sudo bash
set -euo pipefail

# ─── Parse flags ──────────────────────────────────────────────────────────────

RESET=false
UNINSTALL=false
CONFIG_FILE=""
for arg in "$@"; do
  case "$arg" in
    --reset)              RESET=true ;;
    --uninstall)          UNINSTALL=true ;;
    --use-system-docker)  USE_SYSTEM_DOCKER=true ;;
    --config=*)           CONFIG_FILE="${arg#*=}" ;;
    -h|--help)
      echo "Usage: install.sh [OPTIONS]"
      echo ""
      echo "Sandcastle installer — sets up Docker, Sysbox, and the Sandcastle platform."
      echo ""
      echo "Options:"
      echo "  --reset              Tear down existing install before reinstalling"
      echo "  --uninstall          Remove Sandcastle completely (same as --reset, then exit)"
      echo "  --use-system-docker  Use system Docker + Sysbox instead of Dockyard"
      echo "  --config=<file>      Load install config from file (see install-defaults)"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *) echo "Unknown option: $arg (use --help for usage)"; exit 1 ;;
  esac
done

if [ "$UNINSTALL" = true ]; then
  RESET=true
fi

# ─── Defaults (overridable via --config file) ────────────────────────────────

SANDCASTLE_HOME="${SANDCASTLE_HOME:-/sandcastle}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/thieso2/sandcastle:latest}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-ghcr.io/thieso2/sandcastle-sandbox:latest}"
SANDCASTLE_USER="${SANDCASTLE_USER:-sandcastle}"
SANDCASTLE_UID="${SANDCASTLE_UID:-220568}"
SANDCASTLE_GID="${SANDCASTLE_GID:-220568}"
USE_SYSTEM_DOCKER="${USE_SYSTEM_DOCKER:-false}"
SYSBOX_VERSION="${SYSBOX_VERSION:-0.6.6}"
DOCKYARD_ROOT="${DOCKYARD_ROOT:-/sandcastle}"
DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-sc_}"
DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-172.42.89.1/24}"
DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-172.89.91.0/24}"
DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-172.89.0.0/16}"
DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

# ─── Load config file ────────────────────────────────────────────────────────

if [ -n "$CONFIG_FILE" ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  set -a
  source "$CONFIG_FILE"
  set +a
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

# Docker socket path (depends on docker mode)
if [ "$USE_SYSTEM_DOCKER" = true ]; then
  DOCKER_SOCK="/var/run/docker.sock"
else
  DOCKER_SOCK="${DOCKYARD_ROOT}/docker.sock"
fi

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Show available images ──────────────────────────────────────────────────

show_image_info() {
  local repo="$1"
  python3 -c "
import urllib.request, json, sys
repo, arch = '${repo}', '${ARCH}'
try:
    r = urllib.request.urlopen(f'https://ghcr.io/token?scope=repository:thieso2/{repo}:pull')
    token = json.load(r)['token']
    h = {'Authorization': f'Bearer {token}'}
    req = urllib.request.Request(
        f'https://ghcr.io/v2/thieso2/{repo}/manifests/latest',
        headers={**h, 'Accept': 'application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json'})
    m = json.load(urllib.request.urlopen(req))
    if 'manifests' in m:
        for p in m['manifests']:
            if p.get('platform', {}).get('architecture') == arch:
                req = urllib.request.Request(
                    f'https://ghcr.io/v2/thieso2/{repo}/manifests/{p[\"digest\"]}',
                    headers={**h, 'Accept': 'application/vnd.oci.image.manifest.v1+json'})
                m = json.load(urllib.request.urlopen(req))
                break
    cfg = json.load(urllib.request.urlopen(
        urllib.request.Request(f'https://ghcr.io/v2/thieso2/{repo}/blobs/{m[\"config\"][\"digest\"]}', headers=h)))
    import re
    from datetime import datetime, timezone
    # Truncate nanoseconds to microseconds (Python handles max 6 digits)
    ts = re.sub(r'(\.\d{6})\d+', r'\1', cfg['created']).replace('Z', '+00:00')
    dt = datetime.fromisoformat(ts)
    secs = int((datetime.now(timezone.utc) - dt).total_seconds())
    if secs < 0: secs = 0
    if secs >= 86400:
        ago = f'{secs // 86400}d ago'
    elif secs >= 3600:
        ago = f'{secs // 3600}h ago'
    else:
        ago = f'{max(1, secs // 60)}m ago'
    print(f'  ghcr.io/thieso2/{repo}:latest    built {dt.strftime(\"%Y-%m-%d %H:%M UTC\")} ({ago})')
except Exception:
    print(f'  ghcr.io/thieso2/{repo}:latest    (unable to fetch build info)')
" 2>/dev/null || echo "  ghcr.io/thieso2/${repo}:latest"
}

echo ""
echo -e "${BLUE}═══ Sandcastle Installer ═══${NC}"
echo ""
if [ "$UNINSTALL" = false ]; then
  info "Available images (${ARCH}):"
  show_image_info "sandcastle"
  show_image_info "sandcastle-sandbox"
  echo ""
fi

# ─── Helper: find a free private subnet ──────────────────────────────────────

find_free_subnet() {
  # Collect ALL used RFC 1918 IPs from routes, interfaces, and Docker networks
  local used
  used=$(
    { ip route 2>/dev/null; ip addr 2>/dev/null; netstat -rn 2>/dev/null; } \
      | grep -oE '(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' \
      | sort -un
    docker network ls -q 2>/dev/null | while read -r nid; do
      docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$nid" 2>/dev/null
    done | grep -oE '(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' \
      | sort -un
  )

  # Try 172.{16-31}.{random}.0/24 — fully randomized
  for b in $(shuf -i 16-31); do
    for c in $(shuf -i 1-254 | head -5); do
      if ! echo "$used" | grep -q "^172\.${b}\.${c}\."; then
        echo "172.${b}.${c}.0/24"
        return
      fi
    done
  done

  # Fallback: 10.{random}.{random}.0/24
  for b in $(shuf -i 1-254 | head -20); do
    for c in $(shuf -i 1-254 | head -5); do
      if ! echo "$used" | grep -q "^10\.${b}\.${c}\."; then
        echo "10.${b}.${c}.0/24"
        return
      fi
    done
  done

  echo "172.30.99.0/24"  # last resort
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root (use sudo)"
  exit 1
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  warn "This script is tested on Ubuntu 24.04. Other distros may work but are unsupported."
fi

if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
  error "Sandcastle requires amd64 or arm64 architecture (got: $ARCH)"
  exit 1
fi

# ─── Reset (--reset flag) ────────────────────────────────────────────────────

if [ "$RESET" = true ]; then
  # Auto-detect existing docker mode for teardown
  if [ -S "${DOCKYARD_ROOT}/docker.sock" ]; then
    export DOCKER_HOST="unix://${DOCKYARD_ROOT}/docker.sock"
  fi

  # Find existing install: check common locations and .env files
  FOUND_HOME=""
  for candidate in "$SANDCASTLE_HOME" /sandcastle /etc/sandcastle; do
    if [ -f "$candidate/docker-compose.yml" ]; then
      FOUND_HOME="$candidate"
      break
    fi
  done

  if [ -z "$FOUND_HOME" ]; then
    read -rp "Sandcastle home directory to reset: " FOUND_HOME
  fi

  warn "This will destroy ALL data in $FOUND_HOME (containers, volumes, user data, config)"
  read -rp "Are you sure? (yes to confirm): " CONFIRM
  if [ "$CONFIRM" = "yes" ]; then
    info "Tearing down Sandcastle..."
    cd /

    # Stop and remove all Sandcastle-managed containers (sandboxes + Tailscale sidecars)
    for container in $(docker ps -a --filter "name=^sc-ts-" --format '{{.Names}}' 2>/dev/null); do
      info "Removing Tailscale sidecar: $container"
      docker rm -f "$container" 2>/dev/null || true
    done
    for container in $(docker ps -a --filter "label=managed-by=sandcastle" --format '{{.Names}}' 2>/dev/null); do
      info "Removing sandbox: $container"
      docker rm -f "$container" 2>/dev/null || true
    done
    # Also catch sandbox containers by naming convention ({user}-{name})
    for container in $(docker ps -a --filter "runtime=sysbox-runc" --format '{{.Names}}' 2>/dev/null); do
      info "Removing sysbox container: $container"
      docker rm -f "$container" 2>/dev/null || true
    done

    # Remove Tailscale bridge networks
    for net in $(docker network ls --filter "name=^sc-ts-net-" --format '{{.Name}}' 2>/dev/null); do
      info "Removing network: $net"
      docker network rm "$net" 2>/dev/null || true
    done

    # Tear down compose stack
    if [ -f "$FOUND_HOME/docker-compose.yml" ]; then
      docker compose -f "$FOUND_HOME/docker-compose.yml" --env-file "$FOUND_HOME/.env" down --rmi all --volumes --remove-orphans 2>/dev/null || true
    fi
    docker network rm sandcastle-web 2>/dev/null || true

    # Stop Dockyard systemd service if present
    if systemctl is-active --quiet "${DOCKYARD_DOCKER_PREFIX}dockerd" 2>/dev/null; then
      info "Stopping Dockyard..."
      systemctl stop "${DOCKYARD_DOCKER_PREFIX}dockerd" 2>/dev/null || true
      systemctl disable "${DOCKYARD_DOCKER_PREFIX}dockerd" 2>/dev/null || true
      rm -f "/etc/systemd/system/${DOCKYARD_DOCKER_PREFIX}dockerd.service"
      systemctl daemon-reload 2>/dev/null || true
    fi

    # Remove data directory
    rm -rf "$FOUND_HOME"

    # Clear DOCKER_HOST for fresh install
    unset DOCKER_HOST 2>/dev/null || true

    if [ "$UNINSTALL" = true ]; then
      ok "Sandcastle has been uninstalled"
      exit 0
    fi

    ok "Reset complete — running fresh install"
  else
    error "Aborted"
    exit 1
  fi
fi

# ─── Install Docker ──────────────────────────────────────────────────────────

if command -v docker &>/dev/null; then
  ok "Docker already installed"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  ok "Docker installed"
fi

# ─── Install Sysbox or Dockyard ──────────────────────────────────────────────

if [ "$USE_SYSTEM_DOCKER" = true ]; then
  # ─── Sysbox (system Docker mode) ─────────────────────────────────────────
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox; then
    ok "Sysbox already installed"
  else
    info "Installing Sysbox v${SYSBOX_VERSION}..."
    wget -q "https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_${ARCH}.deb" \
      -O /tmp/sysbox.deb
    apt-get install -y /tmp/sysbox.deb
    rm /tmp/sysbox.deb
    systemctl restart docker
    ok "Sysbox installed"
  fi
else
  # ─── Dockyard (isolated Docker + Sysbox) ─────────────────────────────────
  if [ -S "${DOCKYARD_ROOT}/docker.sock" ]; then
    ok "Dockyard already installed"
  else
    info "Installing Dockyard (isolated Docker + Sysbox)..."
    DOCKYARD_TMP="/tmp/dockyard-install"
    rm -rf "$DOCKYARD_TMP"
    mkdir -p "$DOCKYARD_TMP"
    wget -q "https://github.com/thieso2/dockyard/archive/refs/heads/master.tar.gz" -O /tmp/dockyard.tar.gz
    tar -xzf /tmp/dockyard.tar.gz -C "$DOCKYARD_TMP"
    rm /tmp/dockyard.tar.gz

    # Export vars so dockyard's install.sh picks them up from the environment
    export DOCKYARD_ROOT DOCKYARD_DOCKER_PREFIX DOCKYARD_BRIDGE_CIDR
    export DOCKYARD_FIXED_CIDR DOCKYARD_POOL_BASE DOCKYARD_POOL_SIZE

    DOCKYARD_SRC="$(ls -d "$DOCKYARD_TMP"/dockyard-*/)"
    touch "$DOCKYARD_SRC/env.sandcastle"
    cd "$DOCKYARD_SRC"
    bash ./install.sh sandcastle
    cd /
    rm -rf "$DOCKYARD_TMP"

    # Wait for Dockyard socket to be ready
    info "Waiting for Dockyard daemon..."
    for i in $(seq 1 30); do
      if [ -S "${DOCKYARD_ROOT}/docker.sock" ]; then
        break
      fi
      sleep 1
    done
    if [ ! -S "${DOCKYARD_ROOT}/docker.sock" ]; then
      error "Dockyard socket not found at ${DOCKYARD_ROOT}/docker.sock after 30s"
      exit 1
    fi
    ok "Dockyard installed"
  fi

  export DOCKER_HOST="unix://${DOCKYARD_ROOT}/docker.sock"
fi

# ─── Configure UFW ───────────────────────────────────────────────────────────

if command -v ufw &>/dev/null; then
  info "Configuring firewall..."
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw allow 22/tcp >/dev/null 2>&1
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  ufw allow 2201:2299/tcp >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  ok "Firewall configured (22, 80, 443, 2201-2299)"
else
  warn "UFW not found — skipping firewall setup"
fi

# ─── Create sandcastle system user ──────────────────────────────────────────

if getent group "$SANDCASTLE_USER" &>/dev/null; then
  ok "Group '${SANDCASTLE_USER}' already exists"
else
  groupadd --system --gid "$SANDCASTLE_GID" "$SANDCASTLE_USER"
  ok "Created group '${SANDCASTLE_USER}' (GID ${SANDCASTLE_GID})"
fi

if id "$SANDCASTLE_USER" &>/dev/null; then
  ok "User '${SANDCASTLE_USER}' already exists"
else
  useradd --system --uid "$SANDCASTLE_UID" --gid "$SANDCASTLE_GID" --no-create-home --shell /usr/sbin/nologin "$SANDCASTLE_USER"
  ok "Created user '${SANDCASTLE_USER}' (UID ${SANDCASTLE_UID})"
fi

# ─── Sandcastle home directory ────────────────────────────────────────────────

if [ -z "${SANDCASTLE_HOME_CONFIRMED:-}" ]; then
  read -rp "Sandcastle home directory [$SANDCASTLE_HOME]: " INPUT_HOME
  SANDCASTLE_HOME="${INPUT_HOME:-$SANDCASTLE_HOME}"
fi

mkdir -p "$SANDCASTLE_HOME"/data/{users,sandboxes}
mkdir -p "$SANDCASTLE_HOME"/data/traefik/{dynamic,certs}
chown "${SANDCASTLE_USER}:${SANDCASTLE_USER}" "$SANDCASTLE_HOME"
chown -R "${SANDCASTLE_USER}:${SANDCASTLE_USER}" "$SANDCASTLE_HOME"/data/users "$SANDCASTLE_HOME"/data/sandboxes "$SANDCASTLE_HOME"/data/traefik/dynamic
usermod -d "$SANDCASTLE_HOME" "$SANDCASTLE_USER" 2>/dev/null || true

# ─── Detect fresh install vs upgrade ─────────────────────────────────────────

FRESH_INSTALL=false
if [ ! -f "$SANDCASTLE_HOME/.env" ]; then
  FRESH_INSTALL=true
fi

# ─── Configuration ───────────────────────────────────────────────────────────

if [ "$FRESH_INSTALL" = true ]; then
  echo ""
  echo -e "${BLUE}═══ Sandcastle Setup ═══${NC}"
  echo ""

  # Domain or IP — skip prompt if SANDCASTLE_HOST is already set
  if [ -z "${SANDCASTLE_HOST:-}" ]; then
    read -rp "Domain name (leave empty for IP-only mode): " DOMAIN
    if [ -n "$DOMAIN" ]; then
      TLS_MODE="letsencrypt"
      if [ -z "${ACME_EMAIL:-}" ]; then
        read -rp "Email for Let's Encrypt: " ACME_EMAIL
      fi
      if [ -z "$ACME_EMAIL" ]; then
        error "Email is required for Let's Encrypt certificates"
        exit 1
      fi
      SANDCASTLE_HOST="$DOMAIN"
    else
      TLS_MODE="selfsigned"
      # Auto-detect IPv4 address (prefer local, fall back to public)
      PUBLIC_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
      PUBLIC_IP="${PUBLIC_IP:-$(curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null)}"
      PUBLIC_IP="${PUBLIC_IP:-$(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null)}"
      read -rp "Server IP [$PUBLIC_IP]: " INPUT_IP
      SANDCASTLE_HOST="${INPUT_IP:-$PUBLIC_IP}"
      ACME_EMAIL=""
    fi
  else
    # Host set via config — derive TLS mode
    TLS_MODE="${SANDCASTLE_TLS_MODE:-selfsigned}"
    ACME_EMAIL="${ACME_EMAIL:-}"
  fi

  # Admin account — skip prompts if already set via config
  if [ -z "${SANDCASTLE_ADMIN_EMAIL:-}" ]; then
    echo ""
    read -rp "Admin email: " SANDCASTLE_ADMIN_EMAIL
    if [ -z "$SANDCASTLE_ADMIN_EMAIL" ]; then
      error "Admin email is required"
      exit 1
    fi
  fi
  ADMIN_EMAIL="$SANDCASTLE_ADMIN_EMAIL"

  if [ -z "${SANDCASTLE_ADMIN_PASSWORD:-}" ]; then
    while true; do
      read -rsp "Admin password: " SANDCASTLE_ADMIN_PASSWORD
      echo ""
      read -rsp "Confirm password: " ADMIN_PASSWORD_CONFIRM
      echo ""
      if [ "$SANDCASTLE_ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
        break
      fi
      warn "Passwords do not match — try again"
    done
  fi
  ADMIN_PASSWORD="$SANDCASTLE_ADMIN_PASSWORD"
  if [ ${#ADMIN_PASSWORD} -lt 6 ]; then
    error "Password must be at least 6 characters"
    exit 1
  fi

  # SSH public key — skip prompt if already set via config
  if [ -z "${SANDCASTLE_ADMIN_SSH_KEY:-}" ]; then
    echo ""
    DEFAULT_KEY=""
    for keyfile in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
      if [ -f "$keyfile" ]; then
        DEFAULT_KEY=$(cat "$keyfile")
        break
      fi
    done
    if [ -n "$DEFAULT_KEY" ]; then
      SHORT_KEY="${DEFAULT_KEY:0:40}..."
      echo -e "Found SSH key: ${YELLOW}${SHORT_KEY}${NC}"
      read -rp "Use this key? [Y/n]: " USE_DEFAULT
      if [ -z "$USE_DEFAULT" ] || [[ "$USE_DEFAULT" =~ ^[Yy] ]]; then
        SANDCASTLE_ADMIN_SSH_KEY="$DEFAULT_KEY"
      else
        read -rp "Paste your SSH public key: " SANDCASTLE_ADMIN_SSH_KEY
      fi
    else
      read -rp "SSH public key (e.g. ssh-ed25519 AAAA...): " SANDCASTLE_ADMIN_SSH_KEY
    fi
  fi
  ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}"
  if [ -z "$ADMIN_SSH_KEY" ]; then
    warn "No SSH key provided — you can add one later in the web UI"
  fi

  # Docker network subnet — skip prompt if already set via config
  if [ -z "${SANDCASTLE_SUBNET:-}" ]; then
    echo ""
    SUGGESTED_SUBNET=$(find_free_subnet)
    read -rp "Docker network subnet [$SUGGESTED_SUBNET]: " INPUT_SUBNET
    SANDCASTLE_SUBNET="${INPUT_SUBNET:-$SUGGESTED_SUBNET}"
  fi

  # Generate secrets
  SECRET_KEY_BASE=$(openssl rand -hex 64)

  # Detect Docker socket GID
  DOCKER_GID=$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo "988")

  # Write .env
  cat > "$SANDCASTLE_HOME/.env" <<EOF
# Sandcastle configuration — generated $(date -Iseconds)
SANDCASTLE_HOME="$SANDCASTLE_HOME"
SANDCASTLE_HOST="$SANDCASTLE_HOST"
SANDCASTLE_TLS_MODE="$TLS_MODE"
SECRET_KEY_BASE="$SECRET_KEY_BASE"
SANDCASTLE_ADMIN_EMAIL="$ADMIN_EMAIL"
SANDCASTLE_ADMIN_PASSWORD="$ADMIN_PASSWORD"
SANDCASTLE_SUBNET="$SANDCASTLE_SUBNET"
SANDCASTLE_ADMIN_SSH_KEY="$ADMIN_SSH_KEY"
DOCKER_GID="$DOCKER_GID"
DOCKER_SOCK="$DOCKER_SOCK"
ACME_EMAIL="$ACME_EMAIL"
EOF
  chmod 600 "$SANDCASTLE_HOME/.env"
  ok "Configuration written to $SANDCASTLE_HOME/.env"
else
  info "Existing install detected — loading $SANDCASTLE_HOME/.env"
fi

# shellcheck source=/dev/null
source "$SANDCASTLE_HOME/.env"

# Defaults for vars that may be missing in older .env files
if [ -z "${SANDCASTLE_SUBNET:-}" ]; then
  SUGGESTED_SUBNET=$(find_free_subnet)
  read -rp "Docker network subnet [$SUGGESTED_SUBNET]: " INPUT_SUBNET
  SANDCASTLE_SUBNET="${INPUT_SUBNET:-$SUGGESTED_SUBNET}"
  echo "SANDCASTLE_SUBNET=$SANDCASTLE_SUBNET" >> "$SANDCASTLE_HOME/.env"
fi

if [ -z "${DOCKER_SOCK:-}" ]; then
  echo "DOCKER_SOCK=$DOCKER_SOCK" >> "$SANDCASTLE_HOME/.env"
fi

# ─── Traefik config ──────────────────────────────────────────────────────────

TRAEFIK_DIR="$SANDCASTLE_HOME/data/traefik"

if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
  # Generate self-signed cert if missing
  if [ ! -f "$TRAEFIK_DIR/certs/cert.pem" ]; then
    info "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$TRAEFIK_DIR/certs/key.pem" -out "$TRAEFIK_DIR/certs/cert.pem" \
      -subj "/CN=$SANDCASTLE_HOST" \
      -addext "subjectAltName=IP:$SANDCASTLE_HOST" 2>/dev/null
    ok "Self-signed certificate generated"
  fi

  # Traefik static config (self-signed)
  cat > "$TRAEFIK_DIR/traefik.yml" <<'EOF'
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

providers:
  file:
    directory: /data/dynamic
    watch: true

tls:
  certificates:
    - certFile: /data/certs/cert.pem
      keyFile: /data/certs/key.pem

log:
  level: INFO

api:
  dashboard: false
EOF

else
  # Traefik static config (Let's Encrypt)
  cat > "$TRAEFIK_DIR/traefik.yml" <<EOF
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

# ACME storage
if [ ! -f "$TRAEFIK_DIR/acme.json" ]; then
  touch "$TRAEFIK_DIR/acme.json"
  chmod 600 "$TRAEFIK_DIR/acme.json"
fi

# Rails route config for Traefik
if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
  cat > "$TRAEFIK_DIR/dynamic/rails.yml" <<EOF
http:
  routers:
    rails:
      rule: "HostRegexp(\`.+\`)"
      service: rails
      entryPoints:
        - websecure
      tls: {}
  services:
    rails:
      loadBalancer:
        servers:
          - url: "http://sandcastle-web:80"
EOF
else
  cat > "$TRAEFIK_DIR/dynamic/rails.yml" <<EOF
http:
  routers:
    rails:
      rule: "Host(\`${SANDCASTLE_HOST}\`)"
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
fi

# Ensure dynamic config dir is writable by the app container
chown -R "${SANDCASTLE_USER}:${SANDCASTLE_USER}" "$SANDCASTLE_HOME"/data/traefik/dynamic

# ─── Docker network ──────────────────────────────────────────────────────────

if docker network inspect sandcastle-web &>/dev/null; then
  ok "sandcastle-web network exists"
else
  docker network create --subnet "$SANDCASTLE_SUBNET" sandcastle-web >/dev/null
  ok "sandcastle-web network created ($SANDCASTLE_SUBNET)"
fi

# ─── Pull images ─────────────────────────────────────────────────────────────

info "Pulling images..."
docker pull "$APP_IMAGE" &
docker pull "$SANDBOX_IMAGE" &
docker pull traefik:v3.3 &
wait
ok "Images pulled"

# ─── Write docker-compose.yml ────────────────────────────────────────────────

DATA_MOUNT="$SANDCASTLE_HOME/data"

cat > "$SANDCASTLE_HOME/docker-compose.yml" <<COMPOSE
services:
  traefik:
    image: traefik:v3.3
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${DATA_MOUNT}/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ${DATA_MOUNT}/traefik/dynamic:/data/dynamic:ro
      - ${DATA_MOUNT}/traefik/acme.json:/data/acme.json
      - ${DATA_MOUNT}/traefik/certs:/data/certs:ro
    networks:
      - sandcastle-web

  web:
    image: ${APP_IMAGE}
    container_name: sandcastle-web
    group_add:
      - "\${DOCKER_GID:-988}"
    volumes:
      - ${DOCKER_SOCK}:/var/run/docker.sock
      - sandcastle-db:/rails/db
      - sandcastle-storage:/rails/storage
      - ${DATA_MOUNT}:/data
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      SANDCASTLE_HOST: \${SANDCASTLE_HOST}
      SANDCASTLE_DATA_DIR: /data
      SANDCASTLE_TLS_MODE: \${SANDCASTLE_TLS_MODE:-letsencrypt}
      SANDCASTLE_SUBNET: \${SANDCASTLE_SUBNET:-172.30.99.0/24}
      SANDCASTLE_ADMIN_EMAIL: \${SANDCASTLE_ADMIN_EMAIL:-}
      SANDCASTLE_ADMIN_PASSWORD: \${SANDCASTLE_ADMIN_PASSWORD:-}
      SANDCASTLE_ADMIN_SSH_KEY: \${SANDCASTLE_ADMIN_SSH_KEY:-}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    networks:
      - sandcastle-web

  migrate:
    image: ${APP_IMAGE}
    command: ["./bin/rails", "db:prepare"]
    volumes:
      - sandcastle-db:/rails/db
      - sandcastle-storage:/rails/storage
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      SANDCASTLE_ADMIN_EMAIL: \${SANDCASTLE_ADMIN_EMAIL:-}
      SANDCASTLE_ADMIN_PASSWORD: \${SANDCASTLE_ADMIN_PASSWORD:-}
      SANDCASTLE_ADMIN_SSH_KEY: \${SANDCASTLE_ADMIN_SSH_KEY:-}

volumes:
  sandcastle-db:
  sandcastle-storage:

networks:
  sandcastle-web:
    external: true
COMPOSE

ok "docker-compose.yml written"

# ─── Start services ──────────────────────────────────────────────────────────

info "Starting Sandcastle..."
cd "$SANDCASTLE_HOME"
docker compose --env-file .env up -d

# ─── Seed database on fresh install ──────────────────────────────────────────

if [ "$FRESH_INSTALL" = true ]; then
  info "Waiting for app to be ready..."
  for i in $(seq 1 30); do
    if docker compose --env-file .env exec -T web curl -sf http://localhost/up >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  info "Seeding database..."
  docker compose --env-file .env exec -T \
    -e SANDCASTLE_ADMIN_EMAIL="$ADMIN_EMAIL" \
    -e SANDCASTLE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    -e SANDCASTLE_ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}" \
    web ./bin/rails db:seed

fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Sandcastle is running!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
  echo -e "  Dashboard:  ${BLUE}https://${SANDCASTLE_HOST}${NC} (self-signed cert)"
else
  echo -e "  Dashboard:  ${BLUE}https://${SANDCASTLE_HOST}${NC}"
fi

if [ "$FRESH_INSTALL" = true ]; then
  echo ""
  echo -e "  Admin login:"
  echo -e "    Email:     ${YELLOW}${ADMIN_EMAIL}${NC}"
  echo ""
  echo -e "  Tailscale:   ${BLUE}https://${SANDCASTLE_HOST}/tailscale${NC}"
fi

echo ""
echo -e "  Home:       $SANDCASTLE_HOME"
echo -e "  Config:     $SANDCASTLE_HOME/.env"
if [ "$USE_SYSTEM_DOCKER" != true ]; then
  echo -e "  Docker:     DOCKER_HOST=unix://${DOCKYARD_ROOT}/docker.sock"
fi
echo -e "  Logs:       docker compose -f $SANDCASTLE_HOME/docker-compose.yml logs -f"
echo ""
echo -e "  To upgrade: re-run this installer"
echo ""
