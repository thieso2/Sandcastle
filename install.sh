#!/bin/bash
# Sandcastle one-line installer
# curl -fsSL https://install.sandcastle.rocks | sudo bash
set -euo pipefail

SANDCASTLE_DIR="/etc/sandcastle"
DATA_DIR="/data"
SYSBOX_VERSION="0.6.6"
APP_IMAGE="ghcr.io/thieso2/sandcastle:latest"
SANDBOX_IMAGE="ghcr.io/thieso2/sandcastle-sandbox:latest"

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

# ─── Preflight ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root (use sudo)"
  exit 1
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  warn "This script is tested on Ubuntu 24.04. Other distros may work but are unsupported."
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
  error "Sandcastle requires amd64 or arm64 architecture (got: $ARCH)"
  exit 1
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

# ─── Install Sysbox ──────────────────────────────────────────────────────────

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

# ─── Create directories ─────────────────────────────────────────────────────

mkdir -p "$DATA_DIR"/{users,sandboxes}
mkdir -p "$DATA_DIR"/traefik/{dynamic,certs}
chown 220568:220568 "$DATA_DIR"/users "$DATA_DIR"/sandboxes "$DATA_DIR"/traefik/dynamic
mkdir -p "$SANDCASTLE_DIR"

# ─── Detect fresh install vs upgrade ─────────────────────────────────────────

FRESH_INSTALL=false
if [ ! -f "$SANDCASTLE_DIR/.env" ]; then
  FRESH_INSTALL=true
fi

# ─── Configuration ───────────────────────────────────────────────────────────

if [ "$FRESH_INSTALL" = true ]; then
  echo ""
  echo -e "${BLUE}═══ Sandcastle Setup ═══${NC}"
  echo ""

  # Domain or IP
  read -rp "Domain name (leave empty for IP-only mode): " DOMAIN
  if [ -n "$DOMAIN" ]; then
    TLS_MODE="letsencrypt"
    read -rp "Email for Let's Encrypt: " ACME_EMAIL
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

  # Generate secrets
  SECRET_KEY_BASE=$(openssl rand -hex 64)
  ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

  # Detect Docker socket GID
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "988")

  # Write .env
  cat > "$SANDCASTLE_DIR/.env" <<EOF
# Sandcastle configuration — generated $(date -Iseconds)
SANDCASTLE_HOST=$SANDCASTLE_HOST
SANDCASTLE_TLS_MODE=$TLS_MODE
SECRET_KEY_BASE=$SECRET_KEY_BASE
SANDCASTLE_ADMIN_PASSWORD=$ADMIN_PASSWORD
DOCKER_GID=$DOCKER_GID
ACME_EMAIL=$ACME_EMAIL
EOF
  chmod 600 "$SANDCASTLE_DIR/.env"
  ok "Configuration written to $SANDCASTLE_DIR/.env"
else
  info "Existing install detected — loading $SANDCASTLE_DIR/.env"
fi

# shellcheck source=/dev/null
source "$SANDCASTLE_DIR/.env"

# ─── Traefik config ──────────────────────────────────────────────────────────

if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
  # Generate self-signed cert if missing
  CERT_DIR="$DATA_DIR/traefik/certs"
  if [ ! -f "$CERT_DIR/cert.pem" ]; then
    info "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
      -subj "/CN=$SANDCASTLE_HOST" \
      -addext "subjectAltName=IP:$SANDCASTLE_HOST" 2>/dev/null
    ok "Self-signed certificate generated"
  fi

  # Traefik static config (self-signed)
  cat > "$DATA_DIR/traefik/traefik.yml" <<'EOF'
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
  cat > "$DATA_DIR/traefik/traefik.yml" <<EOF
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
if [ ! -f "$DATA_DIR/traefik/acme.json" ]; then
  touch "$DATA_DIR/traefik/acme.json"
  chmod 600 "$DATA_DIR/traefik/acme.json"
fi

# Rails route config for Traefik
if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
  cat > "$DATA_DIR/traefik/dynamic/rails.yml" <<EOF
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
  cat > "$DATA_DIR/traefik/dynamic/rails.yml" <<EOF
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

# ─── Docker network ──────────────────────────────────────────────────────────

if docker network inspect sandcastle-web &>/dev/null; then
  ok "sandcastle-web network exists"
else
  docker network create sandcastle-web >/dev/null
  ok "sandcastle-web network created"
fi

# ─── Pull images ─────────────────────────────────────────────────────────────

info "Pulling images..."
docker pull "$APP_IMAGE" &
docker pull "$SANDBOX_IMAGE" &
docker pull traefik:v3.3 &
wait
ok "Images pulled"

# ─── Write docker-compose.yml ────────────────────────────────────────────────

cat > "$SANDCASTLE_DIR/docker-compose.yml" <<'COMPOSE'
services:
  traefik:
    image: traefik:v3.3
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /data/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - /data/traefik/dynamic:/data/dynamic:ro
      - /data/traefik/acme.json:/data/acme.json
      - /data/traefik/certs:/data/certs:ro
    networks:
      - sandcastle-web

  web:
    image: ghcr.io/thieso2/sandcastle:latest
    container_name: sandcastle-web
    group_add:
      - "${DOCKER_GID:-988}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - sandcastle-db:/rails/db
      - sandcastle-storage:/rails/storage
      - /data:/data
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      SANDCASTLE_HOST: ${SANDCASTLE_HOST}
      SANDCASTLE_DATA_DIR: /data
      SANDCASTLE_TLS_MODE: ${SANDCASTLE_TLS_MODE:-letsencrypt}
      SANDCASTLE_ADMIN_PASSWORD: ${SANDCASTLE_ADMIN_PASSWORD:-}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    networks:
      - sandcastle-web

  migrate:
    image: ghcr.io/thieso2/sandcastle:latest
    command: ["./bin/rails", "db:prepare"]
    volumes:
      - sandcastle-db:/rails/db
      - sandcastle-storage:/rails/storage
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      SANDCASTLE_ADMIN_PASSWORD: ${SANDCASTLE_ADMIN_PASSWORD:-}

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
cd "$SANDCASTLE_DIR"
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
  docker compose --env-file .env exec -T -e SANDCASTLE_ADMIN_PASSWORD="$ADMIN_PASSWORD" web ./bin/rails db:seed
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
  echo -e "    Email:     ${YELLOW}admin@sandcastle.rocks${NC}"
  echo -e "    Password:  ${YELLOW}${ADMIN_PASSWORD}${NC}"
  echo ""
  echo -e "  ${RED}Save these credentials — they won't be shown again.${NC}"
fi

echo ""
echo -e "  Config:     $SANDCASTLE_DIR/.env"
echo -e "  Data:       $DATA_DIR/"
echo -e "  Logs:       docker compose -f $SANDCASTLE_DIR/docker-compose.yml logs -f"
echo ""
echo -e "  To upgrade: re-run this installer"
echo ""
