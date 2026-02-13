#!/bin/bash
# Sandcastle installer
# Usage: installer.sh [gen-env|install|reset|uninstall|help]
set -euo pipefail

# ═══ Colors & helpers ════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

WRITTEN_FILES=()
wrote() { WRITTEN_FILES+=("$1"); }
print_written_files() {
  if [ ${#WRITTEN_FILES[@]} -gt 0 ]; then
    echo ""
    info "Files created/updated:"
    for f in "${WRITTEN_FILES[@]}"; do
      echo -e "    ${f}"
    done
  fi
  WRITTEN_FILES=()
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This command must be run as root (use sudo)"
}

# ═══ Parse command ═══════════════════════════════════════════════════════════

COMMAND="${1:-install}"
shift 2>/dev/null || true

case "$COMMAND" in
  gen-env|install|update|reset|uninstall) ;;
  help|-h|--help) COMMAND="help" ;;
  *) die "Unknown command: $COMMAND (use 'help' for usage)" ;;
esac

# ═══ Help ════════════════════════════════════════════════════════════════════

if [ "$COMMAND" = "help" ]; then
  cat <<'USAGE'
Usage: installer.sh [COMMAND]

Sandcastle installer — sets up Docker (via Dockyard), Traefik, and the
Sandcastle platform.

Commands:
  gen-env      Generate sandcastle.env config file (default: ./sandcastle.env)
  install      Install or upgrade Sandcastle (default)
  update       Pull latest images and restart services
  reset        Tear down existing install, then reinstall
  uninstall    Remove Sandcastle completely
  help         Show this help message

Environment:
  SANDCASTLE_ENV   Path to config file (default search order:
                   ./sandcastle.env → <script_dir>/sandcastle.env →
                   $SANDCASTLE_HOME/etc/sandcastle.env)

Workflow:
  1. installer.sh gen-env              # generate config
  2. vi sandcastle.env                 # edit to taste
  3. sudo installer.sh install         # install (finds ./sandcastle.env)
USAGE
  exit 0
fi

# ═══ load_env ════════════════════════════════════════════════════════════════

load_env() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local home="${SANDCASTLE_HOME:-/sandcastle}"

  LOADED_ENV_FILE=""
  if [ -n "${SANDCASTLE_ENV:-}" ]; then
    [ ! -f "$SANDCASTLE_ENV" ] && die "Env file not found: $SANDCASTLE_ENV"
    LOADED_ENV_FILE="$(cd "$(dirname "$SANDCASTLE_ENV")" && pwd)/$(basename "$SANDCASTLE_ENV")"
  elif [ -f "./sandcastle.env" ]; then
    LOADED_ENV_FILE="$(pwd)/sandcastle.env"
  elif [ -f "$script_dir/sandcastle.env" ]; then
    LOADED_ENV_FILE="$script_dir/sandcastle.env"
  elif [ -f "$home/etc/sandcastle.env" ]; then
    LOADED_ENV_FILE="$home/etc/sandcastle.env"
  fi

  if [ -n "$LOADED_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$LOADED_ENV_FILE"
    set +a
    info "Loaded $LOADED_ENV_FILE"
  fi
}

# ═══ derive_vars ═════════════════════════════════════════════════════════════

derive_vars() {
  SANDCASTLE_HOME="${SANDCASTLE_HOME:-/sandcastle}"
  APP_IMAGE="${APP_IMAGE:-ghcr.io/thieso2/sandcastle:latest}"
  SANDBOX_IMAGE="${SANDBOX_IMAGE:-ghcr.io/thieso2/sandcastle-sandbox:latest}"
  SANDCASTLE_USER="${SANDCASTLE_USER:-sandcastle}"
  SANDCASTLE_GROUP="${SANDCASTLE_GROUP:-$SANDCASTLE_USER}"
  SANDCASTLE_UID="${SANDCASTLE_UID:-220568}"
  SANDCASTLE_GID="${SANDCASTLE_GID:-220568}"
  SANDCASTLE_HTTP_PORT="${SANDCASTLE_HTTP_PORT:-80}"
  SANDCASTLE_HTTPS_PORT="${SANDCASTLE_HTTPS_PORT:-443}"
  SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE:-selfsigned}"

  DOCKYARD_ROOT="${DOCKYARD_ROOT:-$SANDCASTLE_HOME}"
  DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-sc_}"
  DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-172.42.89.1/24}"
  DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-172.42.89.0/24}"
  DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-172.89.0.0/16}"
  DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

  DOCKER_SOCK="${DOCKYARD_ROOT}/docker.sock"
  DOCKER="${DOCKYARD_ROOT}/docker-runtime/bin/docker"

  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

  # Resolve password from file if needed
  if [ -z "${SANDCASTLE_ADMIN_PASSWORD:-}" ] && [ -n "${SANDCASTLE_ADMIN_PASSWORD_FILE:-}" ]; then
    [ ! -f "$SANDCASTLE_ADMIN_PASSWORD_FILE" ] && die "Password file not found: $SANDCASTLE_ADMIN_PASSWORD_FILE"
    SANDCASTLE_ADMIN_PASSWORD="$(cat "$SANDCASTLE_ADMIN_PASSWORD_FILE")"
  fi
}

# ═══ ensure_dirs ═════════════════════════════════════════════════════════
# Create/fix data directories and ownership. Safe to run repeatedly.

ensure_dirs() {
  mkdir -p "$SANDCASTLE_HOME"/etc
  mkdir -p "$SANDCASTLE_HOME"/data/{users,sandboxes,wetty}
  mkdir -p "$SANDCASTLE_HOME"/data/traefik/{dynamic,certs}
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$SANDCASTLE_HOME"
  # Own top-level data dirs (not -R: per-user subdirs are bind-mounted into
  # Sysbox containers which use a different UID range via /etc/subuid).
  chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" \
    "$SANDCASTLE_HOME"/data/users \
    "$SANDCASTLE_HOME"/data/sandboxes \
    "$SANDCASTLE_HOME"/data/wetty
  chown -R "${SANDCASTLE_UID}:${SANDCASTLE_GID}" \
    "$SANDCASTLE_HOME"/data/traefik/dynamic
  # Per-user dirs: own the user-level parent, then chmod 777 the bind-mount
  # targets so Sysbox-mapped root can write to them.
  for d in "$SANDCASTLE_HOME"/data/users/*; do
    [ -d "$d" ] && chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" "$d"
  done
  for d in "$SANDCASTLE_HOME"/data/users/*/home \
           "$SANDCASTLE_HOME"/data/users/*/data \
           "$SANDCASTLE_HOME"/data/sandboxes/*/vol; do
    [ -d "$d" ] && chmod 777 "$d"
  done
  usermod -d "$SANDCASTLE_HOME" "$SANDCASTLE_USER" 2>/dev/null || true
  ok "Data directories verified"
}

# ═══ Helpers ═════════════════════════════════════════════════════════════════

show_image_info() {
  local repo="$1"
  python3 -c "
import urllib.request, json, sys, re
from datetime import datetime, timezone
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
    ts = re.sub(r'(\.\d{6})\d+', r'\1', cfg['created']).replace('Z', '+00:00')
    dt = datetime.fromisoformat(ts)
    secs = int((datetime.now(timezone.utc) - dt).total_seconds())
    if secs < 0: secs = 0
    if secs >= 86400: ago = f'{secs // 86400}d ago'
    elif secs >= 3600: ago = f'{secs // 3600}h ago'
    else: ago = f'{max(1, secs // 60)}m ago'
    print(f'  ghcr.io/thieso2/{repo}:latest    built {dt.strftime(\"%Y-%m-%d %H:%M UTC\")} ({ago})')
except Exception:
    print(f'  ghcr.io/thieso2/{repo}:latest    (unable to fetch build info)')
" 2>/dev/null || echo "  ghcr.io/thieso2/${repo}:latest"
}

find_free_subnet() {
  local used
  used=$(
    { ip route 2>/dev/null; ip addr 2>/dev/null; netstat -rn 2>/dev/null; } \
      | grep -oE '(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' \
      | sort -un
    $DOCKER network ls -q 2>/dev/null | while read -r nid; do
      $DOCKER network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$nid" 2>/dev/null
    done | grep -oE '(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' \
      | sort -un
  )
  for b in $(shuf -i 16-31); do
    for c in $(shuf -i 1-254 | head -5); do
      if ! echo "$used" | grep -q "^172\.${b}\.${c}\."; then
        echo "172.${b}.${c}.0/24"
        return
      fi
    done
  done
  for b in $(shuf -i 1-254 | head -20); do
    for c in $(shuf -i 1-254 | head -5); do
      if ! echo "$used" | grep -q "^10\.${b}\.${c}\."; then
        echo "10.${b}.${c}.0/24"
        return
      fi
    done
  done
  echo "172.30.99.0/24"
}

# ═══ write_compose ══════════════════════════════════════════════════════════

write_helper_scripts() {
  cat > "${DOCKYARD_ROOT}/docker-runtime/bin/docker-logs" <<LOGS
#!/bin/bash
exec sudo ${DOCKER} compose -f ${SANDCASTLE_HOME}/docker-compose.yml --env-file ${SANDCASTLE_HOME}/.env logs -f "\$@"
LOGS
  chmod +x "${DOCKYARD_ROOT}/docker-runtime/bin/docker-logs"
  wrote "${DOCKYARD_ROOT}/docker-runtime/bin/docker-logs"
}

write_compose() {
  local DATA_MOUNT="$SANDCASTLE_HOME/data"

  cat > "$SANDCASTLE_HOME/docker-compose.yml" <<COMPOSE
services:
  traefik:
    image: traefik:v3.3
    runtime: runc
    restart: unless-stopped
    ports:
      - "${SANDCASTLE_HTTP_PORT}:80"
      - "${SANDCASTLE_HTTPS_PORT}:443"
    volumes:
      - ${DATA_MOUNT}/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ${DATA_MOUNT}/traefik/dynamic:/data/dynamic:ro
      - ${DATA_MOUNT}/traefik/acme.json:/data/acme.json
      - ${DATA_MOUNT}/traefik/certs:/data/certs:ro
    networks:
      - sandcastle-web

  postgres:
    image: postgres:18
    runtime: runc
    restart: unless-stopped
    volumes:
      - ${SANDCASTLE_HOME}/pgdata:/var/lib/postgresql
      - ${SANDCASTLE_HOME}/etc/postgres/init-databases.sh:/docker-entrypoint-initdb.d/init-databases.sh:ro
    environment:
      POSTGRES_USER: sandcastle
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_DB: sandcastle_production
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sandcastle -d sandcastle_production"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - sandcastle-web

  web:
    image: ${APP_IMAGE}
    runtime: runc
    container_name: sandcastle-web
    group_add:
      - "\${DOCKER_GID:-988}"
    volumes:
      - \${DOCKER_SOCK}:/var/run/docker.sock
      - ${DATA_MOUNT}:${DATA_MOUNT}
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      SANDCASTLE_HOST: \${SANDCASTLE_HOST}
      SANDCASTLE_DATA_DIR: ${DATA_MOUNT}
      SANDCASTLE_TLS_MODE: \${SANDCASTLE_TLS_MODE:-letsencrypt}
      SANDCASTLE_SUBNET: \${SANDCASTLE_SUBNET:-172.30.99.0/24}
      SANDCASTLE_ADMIN_EMAIL: \${SANDCASTLE_ADMIN_EMAIL:-}
      SANDCASTLE_ADMIN_PASSWORD: \${SANDCASTLE_ADMIN_PASSWORD:-}
      SANDCASTLE_ADMIN_SSH_KEY: \${SANDCASTLE_ADMIN_SSH_KEY:-}
      DB_HOST: postgres
      DB_USER: sandcastle
      DB_PASSWORD: \${DB_PASSWORD}
      GITHUB_CLIENT_ID: \${GITHUB_CLIENT_ID:-}
      GITHUB_CLIENT_SECRET: \${GITHUB_CLIENT_SECRET:-}
      GOOGLE_CLIENT_ID: \${GOOGLE_CLIENT_ID:-}
      GOOGLE_CLIENT_SECRET: \${GOOGLE_CLIENT_SECRET:-}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    networks:
      - sandcastle-web

  migrate:
    image: ${APP_IMAGE}
    runtime: runc
    command: ["./bin/rails", "db:prepare"]
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      SANDCASTLE_ADMIN_EMAIL: \${SANDCASTLE_ADMIN_EMAIL:-}
      SANDCASTLE_ADMIN_PASSWORD: \${SANDCASTLE_ADMIN_PASSWORD:-}
      SANDCASTLE_ADMIN_SSH_KEY: \${SANDCASTLE_ADMIN_SSH_KEY:-}
      DB_HOST: postgres
      DB_USER: sandcastle
      DB_PASSWORD: \${DB_PASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - sandcastle-web

networks:
  sandcastle-web:
    external: true
COMPOSE

  wrote "$SANDCASTLE_HOME/docker-compose.yml"
}

# ═══ cmd_gen_env ═════════════════════════════════════════════════════════════

cmd_gen_env() {
  local out="${SANDCASTLE_ENV:-./sandcastle.env}"
  [ -f "$out" ] && die "File already exists: $out"

  local home="${SANDCASTLE_HOME:-/sandcastle}"
  local app_image="${APP_IMAGE:-ghcr.io/thieso2/sandcastle:latest}"
  local sandbox_image="${SANDBOX_IMAGE:-ghcr.io/thieso2/sandcastle-sandbox:latest}"
  local user="${SANDCASTLE_USER:-sandcastle}"
  local group="${SANDCASTLE_GROUP:-$user}"
  local uid="${SANDCASTLE_UID:-220568}"
  local gid="${SANDCASTLE_GID:-220568}"
  local http_port="${SANDCASTLE_HTTP_PORT:-80}"
  local https_port="${SANDCASTLE_HTTPS_PORT:-443}"
  local tls_mode="${SANDCASTLE_TLS_MODE:-selfsigned}"

  # Auto-detect host IP
  local host="${SANDCASTLE_HOST:-}"
  if [ -z "$host" ]; then
    host=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)
    host="${host:-$(curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)}"
    host="${host:-0.0.0.0}"
  fi

  local admin_email="${SANDCASTLE_ADMIN_EMAIL:-admin@example.com}"

  local dy_root="${DOCKYARD_ROOT:-$home}"
  local dy_prefix="${DOCKYARD_DOCKER_PREFIX:-sc_}"
  local dy_bridge="${DOCKYARD_BRIDGE_CIDR:-172.42.89.1/24}"
  local dy_fixed="${DOCKYARD_FIXED_CIDR:-172.42.89.0/24}"
  local dy_pool="${DOCKYARD_POOL_BASE:-172.89.0.0/16}"
  local dy_pool_size="${DOCKYARD_POOL_SIZE:-24}"

  cat > "$out" <<EOF
# Sandcastle configuration
# Edit values below, then run: sudo installer.sh install

# ─── Paths & images ─────────────────────────────────────────────────────────
SANDCASTLE_HOME=${home}
APP_IMAGE=${app_image}
SANDBOX_IMAGE=${sandbox_image}

# ─── System user (home=SANDCASTLE_HOME, shell=/bin/bash) ────────────────────
SANDCASTLE_USER=${user}
SANDCASTLE_GROUP=${group}
SANDCASTLE_UID=${uid}
SANDCASTLE_GID=${gid}

# ─── Network & TLS ──────────────────────────────────────────────────────────
SANDCASTLE_HOST=${host}
SANDCASTLE_TLS_MODE=${tls_mode}
#ACME_EMAIL=admin@example.com
SANDCASTLE_HTTP_PORT=${http_port}
SANDCASTLE_HTTPS_PORT=${https_port}
#SANDCASTLE_SUBNET=

# ─── Admin account (required for fresh install) ─────────────────────────────
SANDCASTLE_ADMIN_EMAIL=${admin_email}
#SANDCASTLE_ADMIN_PASSWORD=changeme
#SANDCASTLE_ADMIN_PASSWORD_FILE=/path/to/password-file
#SANDCASTLE_ADMIN_SSH_KEY=ssh-ed25519 AAAA...

# ─── OAuth (optional — enables "Sign in with …" buttons) ──────────────────
#GITHUB_CLIENT_ID=
#GITHUB_CLIENT_SECRET=
#GOOGLE_CLIENT_ID=
#GOOGLE_CLIENT_SECRET=

# ─── Dockyard (Docker + Sysbox) ─────────────────────────────────────────────
DOCKYARD_ROOT=${dy_root}
DOCKYARD_DOCKER_PREFIX=${dy_prefix}
DOCKYARD_BRIDGE_CIDR=${dy_bridge}
DOCKYARD_FIXED_CIDR=${dy_fixed}
DOCKYARD_POOL_BASE=${dy_pool}
DOCKYARD_POOL_SIZE=${dy_pool_size}
EOF

  ok "Generated $out — edit it, then run: sudo installer.sh install"
}

# ═══ cmd_destroy ═════════════════════════════════════════════════════════════

cmd_destroy() {
  local auto_confirm="${1:-false}"

  require_root

  # Load installed env for CREATED_USER/CREATED_GROUP
  if [ -f "$SANDCASTLE_HOME/etc/sandcastle.env" ]; then
    # shellcheck source=/dev/null
    source "$SANDCASTLE_HOME/etc/sandcastle.env"
  fi

  warn "This will remove Sandcastle from $SANDCASTLE_HOME (containers, config, services)"
  if [ "$auto_confirm" != "true" ]; then
    read -rp "Are you sure? (yes to confirm): " CONFIRM
    [ "$CONFIRM" = "yes" ] || die "Aborted"
  fi

  info "Tearing down Sandcastle..."
  cd /

  if [ -x "$DOCKER" ]; then
    for container in $($DOCKER ps -a --filter "name=^sc-ts-" --format '{{.Names}}' 2>/dev/null); do
      info "Removing Tailscale sidecar: $container"
      $DOCKER rm -f "$container" 2>/dev/null || true
    done
    for container in $($DOCKER ps -a --filter "runtime=sysbox-runc" --format '{{.Names}}' 2>/dev/null); do
      info "Removing container: $container"
      $DOCKER rm -f "$container" 2>/dev/null || true
    done
    for net in $($DOCKER network ls --filter "name=^sc-ts-net-" --format '{{.Name}}' 2>/dev/null); do
      info "Removing network: $net"
      $DOCKER network rm "$net" 2>/dev/null || true
    done
    if [ -f "$SANDCASTLE_HOME/docker-compose.yml" ]; then
      $DOCKER compose -f "$SANDCASTLE_HOME/docker-compose.yml" --env-file "$SANDCASTLE_HOME/.env" down --rmi all --volumes --remove-orphans 2>/dev/null || true
    fi
    $DOCKER network rm sandcastle-web 2>/dev/null || true
  fi

  # Destroy Dockyard
  DOCKYARD_ENV_FILE="$SANDCASTLE_HOME/etc/dockyard.env"
  if [ -f "$DOCKYARD_ENV_FILE" ] || systemctl cat "${DOCKYARD_DOCKER_PREFIX}docker.service" &>/dev/null; then
    info "Destroying Dockyard..."
    if [ -f "$DOCKYARD_ENV_FILE" ] && wget -q "https://raw.githubusercontent.com/thieso2/dockyard/refs/heads/main/dockyard.sh" -O /tmp/dockyard.sh 2>/dev/null; then
      echo "y" | DOCKYARD_ENV="$DOCKYARD_ENV_FILE" bash /tmp/dockyard.sh destroy >/dev/null 2>&1 || true
      rm -f /tmp/dockyard.sh
    else
      systemctl stop "${DOCKYARD_DOCKER_PREFIX}docker" 2>/dev/null || true
      systemctl disable "${DOCKYARD_DOCKER_PREFIX}docker" 2>/dev/null || true
      rm -f "/etc/systemd/system/${DOCKYARD_DOCKER_PREFIX}docker.service"
      systemctl daemon-reload 2>/dev/null || true
      ip link delete "${DOCKYARD_DOCKER_PREFIX}docker0" 2>/dev/null || true
    fi
    ok "Dockyard destroyed"
  fi

  # Remove user/group if we created them
  if [ "${CREATED_USER:-}" = "true" ] && id "$SANDCASTLE_USER" &>/dev/null; then
    userdel "$SANDCASTLE_USER" 2>/dev/null || true
    ok "Removed user '${SANDCASTLE_USER}'"
  fi
  if [ "${CREATED_GROUP:-}" = "true" ] && getent group "$SANDCASTLE_GROUP" &>/dev/null; then
    groupdel "$SANDCASTLE_GROUP" 2>/dev/null || true
    ok "Removed group '${SANDCASTLE_GROUP}'"
  fi

  # Remove NAT service
  if [ -f /etc/systemd/system/sandcastle-nat.service ]; then
    systemctl disable --now sandcastle-nat 2>/dev/null || true
    rm -f /etc/systemd/system/sandcastle-nat.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Remove Sandcastle files — keep user data (data/users, data/sandboxes)
  rm -f "$SANDCASTLE_HOME/.env"
  rm -f "$SANDCASTLE_HOME/docker-compose.yml"
  rm -rf "$SANDCASTLE_HOME/etc"
  rm -rf "$SANDCASTLE_HOME/data/traefik"
  rmdir "$SANDCASTLE_HOME/data" 2>/dev/null || true
  rmdir "$SANDCASTLE_HOME" 2>/dev/null || true
  rm -rf "/run/${DOCKYARD_DOCKER_PREFIX}docker"

  if [ -d "$SANDCASTLE_HOME/data/users" ] || [ -d "$SANDCASTLE_HOME/data/sandboxes" ]; then
    warn "User data preserved in $SANDCASTLE_HOME/data/ — remove manually if no longer needed"
  fi

  ok "Sandcastle destroyed"
}

# ═══ cmd_install ═════════════════════════════════════════════════════════════

cmd_install() {
  require_root

  if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    warn "This script is tested on Ubuntu 24.04. Other distros may work but are unsupported."
  fi
  if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
    die "Sandcastle requires amd64 or arm64 architecture (got: $ARCH)"
  fi

  echo ""
  echo -e "${BLUE}═══ Sandcastle Installer ═══${NC}"
  echo ""
  info "Available images (${ARCH}):"
  show_image_info "sandcastle"
  show_image_info "sandcastle-sandbox"
  echo ""

  # ── Install Dockyard ──────────────────────────────────────────────────────

  if [ -S "$DOCKER_SOCK" ]; then
    ok "Dockyard already installed"
  else
    info "Installing Dockyard (Docker + Sysbox)..."
    wget -q "https://raw.githubusercontent.com/thieso2/dockyard/refs/heads/main/dockyard.sh" -O /tmp/dockyard.sh

    mkdir -p "$SANDCASTLE_HOME/etc"
    cat > "$SANDCASTLE_HOME/etc/dockyard.env" <<DYEOF
DOCKYARD_ROOT=${DOCKYARD_ROOT}
DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}
DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}
DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}
DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}
DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}
DYEOF
    wrote "$SANDCASTLE_HOME/etc/dockyard.env"

    DOCKYARD_ENV="$SANDCASTLE_HOME/etc/dockyard.env" bash /tmp/dockyard.sh create
    rm -f /tmp/dockyard.sh

    for i in $(seq 1 30); do
      [ -S "$DOCKER_SOCK" ] && break
      sleep 1
    done
    [ -S "$DOCKER_SOCK" ] || die "Dockyard socket not found at $DOCKER_SOCK after 30s"
    ok "Dockyard installed"
  fi

  # ── Configure UFW ─────────────────────────────────────────────────────────

  if command -v ufw &>/dev/null; then
    info "Configuring firewall..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow "${SANDCASTLE_HTTP_PORT}/tcp" >/dev/null 2>&1
    ufw allow "${SANDCASTLE_HTTPS_PORT}/tcp" >/dev/null 2>&1
    ufw allow 2201:2299/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "Firewall configured (22, ${SANDCASTLE_HTTP_PORT}, ${SANDCASTLE_HTTPS_PORT}, 2201-2299)"
  else
    warn "UFW not found — skipping firewall setup"
  fi

  # ── Create system user/group ──────────────────────────────────────────────

  CREATED_GROUP=false
  CREATED_USER=false

  if getent group "$SANDCASTLE_GROUP" &>/dev/null; then
    ok "Group '${SANDCASTLE_GROUP}' already exists"
  else
    groupadd --system --gid "$SANDCASTLE_GID" "$SANDCASTLE_GROUP"
    CREATED_GROUP=true
    ok "Created group '${SANDCASTLE_GROUP}' (GID ${SANDCASTLE_GID})"
  fi

  if id "$SANDCASTLE_USER" &>/dev/null; then
    ok "User '${SANDCASTLE_USER}' already exists"
  else
    useradd --system --uid "$SANDCASTLE_UID" --gid "$SANDCASTLE_GID" \
      --home-dir "$SANDCASTLE_HOME" --shell /bin/bash "$SANDCASTLE_USER"
    CREATED_USER=true
    ok "Created user '${SANDCASTLE_USER}' (UID ${SANDCASTLE_UID})"
  fi

  # ── Create directories ────────────────────────────────────────────────────

  ensure_dirs

  # ── Detect fresh install vs upgrade ─────────────────────────────────────

  FRESH_INSTALL=false
  [ ! -f "$SANDCASTLE_HOME/.env" ] && FRESH_INSTALL=true

  # ── Fresh install: validate & generate .env ─────────────────────────────

  if [ "$FRESH_INSTALL" = true ]; then
    [ -z "${SANDCASTLE_HOST:-}" ] && die "SANDCASTLE_HOST is required (set in sandcastle.env)"
    [ -z "${SANDCASTLE_ADMIN_EMAIL:-}" ] && die "SANDCASTLE_ADMIN_EMAIL is required (set in sandcastle.env)"
    [ -z "${SANDCASTLE_ADMIN_PASSWORD:-}" ] && die "SANDCASTLE_ADMIN_PASSWORD is required (set in sandcastle.env or use SANDCASTLE_ADMIN_PASSWORD_FILE)"
    [ ${#SANDCASTLE_ADMIN_PASSWORD} -lt 6 ] && die "SANDCASTLE_ADMIN_PASSWORD must be at least 6 characters"

    if [ -z "${SANDCASTLE_SUBNET:-}" ]; then
      SANDCASTLE_SUBNET=$(find_free_subnet)
      info "Auto-detected subnet: $SANDCASTLE_SUBNET"
    fi

    SECRET_KEY_BASE=$(openssl rand -hex 64)
    DB_PASSWORD=$(openssl rand -hex 32)
    DOCKER_GID=$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo "988")

    cat > "$SANDCASTLE_HOME/.env" <<EOF
# Sandcastle runtime — generated $(date -Iseconds)
SANDCASTLE_HOME="${SANDCASTLE_HOME}"
SANDCASTLE_HOST="${SANDCASTLE_HOST}"
SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE}"
SECRET_KEY_BASE="${SECRET_KEY_BASE}"
DB_PASSWORD="${DB_PASSWORD}"
SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL}"
SANDCASTLE_ADMIN_PASSWORD="${SANDCASTLE_ADMIN_PASSWORD}"
SANDCASTLE_SUBNET="${SANDCASTLE_SUBNET}"
SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}"
DOCKER_GID="${DOCKER_GID}"
DOCKER_SOCK="${DOCKER_SOCK}"
ACME_EMAIL="${ACME_EMAIL:-}"
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
EOF
    chmod 600 "$SANDCASTLE_HOME/.env"
    wrote "$SANDCASTLE_HOME/.env"
  else
    info "Existing install — loading $SANDCASTLE_HOME/.env"
  fi

  # shellcheck source=/dev/null
  source "$SANDCASTLE_HOME/.env"

  # Backfill vars that may be missing in older .env files
  if [ -z "${SANDCASTLE_SUBNET:-}" ]; then
    SANDCASTLE_SUBNET=$(find_free_subnet)
    echo "SANDCASTLE_SUBNET=$SANDCASTLE_SUBNET" >> "$SANDCASTLE_HOME/.env"
  fi
  if [ -z "${DOCKER_SOCK:-}" ]; then
    DOCKER_SOCK="${DOCKYARD_ROOT}/docker.sock"
    echo "DOCKER_SOCK=$DOCKER_SOCK" >> "$SANDCASTLE_HOME/.env"
  fi
  # Backfill OAuth vars from sandcastle.env into .env
  grep -q '^GITHUB_CLIENT_ID=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GITHUB_CLIENT_SECRET=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GOOGLE_CLIENT_ID=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GOOGLE_CLIENT_SECRET=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}" >> "$SANDCASTLE_HOME/.env"

  # ── Write installed sandcastle.env ────────────────────────────────────────

  cat > "$SANDCASTLE_HOME/etc/sandcastle.env" <<EOF
# Sandcastle installed configuration — generated $(date -Iseconds)
SANDCASTLE_HOME="${SANDCASTLE_HOME}"
APP_IMAGE="${APP_IMAGE}"
SANDBOX_IMAGE="${SANDBOX_IMAGE}"
SANDCASTLE_USER="${SANDCASTLE_USER}"
SANDCASTLE_GROUP="${SANDCASTLE_GROUP}"
SANDCASTLE_UID="${SANDCASTLE_UID}"
SANDCASTLE_GID="${SANDCASTLE_GID}"
SANDCASTLE_HOST="${SANDCASTLE_HOST}"
SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE}"
SANDCASTLE_HTTP_PORT="${SANDCASTLE_HTTP_PORT}"
SANDCASTLE_HTTPS_PORT="${SANDCASTLE_HTTPS_PORT}"
SANDCASTLE_SUBNET="${SANDCASTLE_SUBNET}"
SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL:-}"
SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
DOCKYARD_ROOT="${DOCKYARD_ROOT}"
DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX}"
DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR}"
DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR}"
DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE}"
DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE}"
DOCKER_SOCK="${DOCKER_SOCK}"
DOCKER_GID="${DOCKER_GID:-988}"
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
CREATED_USER="${CREATED_USER}"
CREATED_GROUP="${CREATED_GROUP}"
EOF
  chmod 600 "$SANDCASTLE_HOME/etc/sandcastle.env"
  wrote "$SANDCASTLE_HOME/etc/sandcastle.env"

  # ── Traefik config ────────────────────────────────────────────────────────

  TRAEFIK_DIR="$SANDCASTLE_HOME/data/traefik"

  if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
    if [ ! -f "$TRAEFIK_DIR/certs/cert.pem" ]; then
      info "Generating self-signed certificate..."
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$TRAEFIK_DIR/certs/key.pem" -out "$TRAEFIK_DIR/certs/cert.pem" \
        -subj "/CN=$SANDCASTLE_HOST" \
        -addext "subjectAltName=IP:$SANDCASTLE_HOST" 2>/dev/null
      ok "Self-signed certificate generated"
    fi

    cat > "$TRAEFIK_DIR/traefik.yml" <<'TEOF'
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
TEOF

  else
    cat > "$TRAEFIK_DIR/traefik.yml" <<TEOF
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
TEOF
  fi
  wrote "$TRAEFIK_DIR/traefik.yml"

  if [ ! -f "$TRAEFIK_DIR/acme.json" ]; then
    touch "$TRAEFIK_DIR/acme.json"
    chmod 600 "$TRAEFIK_DIR/acme.json"
  fi

  if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
    cat > "$TRAEFIK_DIR/dynamic/rails.yml" <<TEOF
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
TEOF
  else
    cat > "$TRAEFIK_DIR/dynamic/rails.yml" <<TEOF
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
TEOF
  fi
  wrote "$TRAEFIK_DIR/dynamic/rails.yml"

  chown -R "${SANDCASTLE_UID}:${SANDCASTLE_GID}" "$SANDCASTLE_HOME"/data/traefik/dynamic

  # ── Docker network ────────────────────────────────────────────────────────

  if $DOCKER network inspect sandcastle-web &>/dev/null; then
    ok "sandcastle-web network exists"
  else
    $DOCKER network create --subnet "$SANDCASTLE_SUBNET" sandcastle-web >/dev/null
    ok "sandcastle-web network created ($SANDCASTLE_SUBNET)"
  fi

  # ── NAT & forwarding for sandcastle networks ─────────────────────────────
  # Dockyard runs with --iptables=false, so user-defined networks (sandcastle-web,
  # per-user Tailscale bridges) have no MASQUERADE or FORWARD rules.
  # Cover all of them with a single /16 derived from SANDCASTLE_SUBNET.

  SANDCASTLE_NAT_CIDR=$(echo "$SANDCASTLE_SUBNET" | awk -F'[./]' '{print $1"."$2".0.0/16"}')

  iptables -t nat -C POSTROUTING -s "$SANDCASTLE_NAT_CIDR" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$SANDCASTLE_NAT_CIDR" -j MASQUERADE
  iptables -C FORWARD -s "$SANDCASTLE_NAT_CIDR" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -s "$SANDCASTLE_NAT_CIDR" -j ACCEPT
  iptables -C FORWARD -d "$SANDCASTLE_NAT_CIDR" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -d "$SANDCASTLE_NAT_CIDR" -j ACCEPT
  ok "NAT rules added for $SANDCASTLE_NAT_CIDR"

  # Persist across reboots via systemd
  cat > /etc/systemd/system/sandcastle-nat.service <<NATEOF
[Unit]
Description=Sandcastle NAT and forwarding rules
After=${DOCKYARD_DOCKER_PREFIX}docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s ${SANDCASTLE_NAT_CIDR} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${SANDCASTLE_NAT_CIDR} -j MASQUERADE'
ExecStart=/bin/sh -c 'iptables -C FORWARD -s ${SANDCASTLE_NAT_CIDR} -j ACCEPT 2>/dev/null || iptables -I FORWARD -s ${SANDCASTLE_NAT_CIDR} -j ACCEPT'
ExecStart=/bin/sh -c 'iptables -C FORWARD -d ${SANDCASTLE_NAT_CIDR} -j ACCEPT 2>/dev/null || iptables -I FORWARD -d ${SANDCASTLE_NAT_CIDR} -j ACCEPT'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NATEOF
  systemctl daemon-reload
  systemctl enable sandcastle-nat >/dev/null 2>&1
  wrote "/etc/systemd/system/sandcastle-nat.service"

  # ── Pull images ───────────────────────────────────────────────────────────

  info "Pulling images..."
  $DOCKER pull "$APP_IMAGE" &
  $DOCKER pull "$SANDBOX_IMAGE" &
  $DOCKER pull traefik:v3.3 &
  wait
  ok "Images pulled"

  # ── Write PostgreSQL init script ──────────────────────────────────────────

  mkdir -p "$SANDCASTLE_HOME/etc/postgres"
  cat > "$SANDCASTLE_HOME/etc/postgres/init-databases.sh" <<'INITDB'
#!/bin/bash
set -e
for db in sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE $db OWNER $POSTGRES_USER'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
EOSQL
done
INITDB
  chmod +x "$SANDCASTLE_HOME/etc/postgres/init-databases.sh"
  wrote "$SANDCASTLE_HOME/etc/postgres/init-databases.sh"

  write_compose

  write_helper_scripts

  # ── Start services ────────────────────────────────────────────────────────

  info "Starting Sandcastle..."
  cd "$SANDCASTLE_HOME"
  $DOCKER compose --env-file .env up -d

  # ── Seed database (fresh install) ─────────────────────────────────────────

  if [ "$FRESH_INSTALL" = true ]; then
    info "Waiting for app to be ready..."
    for i in $(seq 1 30); do
      if curl -sfk https://localhost:${SANDCASTLE_HTTPS_PORT}/up >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    info "Seeding database..."
    $DOCKER compose --env-file .env exec -T \
      -e SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL}" \
      -e SANDCASTLE_ADMIN_PASSWORD="${SANDCASTLE_ADMIN_PASSWORD}" \
      -e SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}" \
      web ./bin/rails db:seed
  fi

  # ── Done ──────────────────────────────────────────────────────────────────

  # Build base URL with port suffix only when non-standard
  local port_suffix=""
  [ "$SANDCASTLE_HTTPS_PORT" != "443" ] && port_suffix=":${SANDCASTLE_HTTPS_PORT}"
  local base_url="https://${SANDCASTLE_HOST}${port_suffix}"

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Sandcastle is running!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo ""

  if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ]; then
    echo -e "  Dashboard:  ${BLUE}${base_url}${NC} (self-signed cert)"
  else
    echo -e "  Dashboard:  ${BLUE}${base_url}${NC}"
  fi

  if [ "$FRESH_INSTALL" = true ]; then
    echo ""
    echo -e "  Admin login:"
    echo -e "    Email:     ${YELLOW}${SANDCASTLE_ADMIN_EMAIL}${NC}"
    echo ""
    echo -e "  Tailscale:   ${BLUE}${base_url}/tailscale${NC}"
  fi

  echo ""
  echo -e "  Home:       $SANDCASTLE_HOME"
  echo -e "  Config:     $SANDCASTLE_HOME/etc/sandcastle.env"
  echo -e "  Docker:     $DOCKER"
  echo -e "  Logs:       ${DOCKYARD_ROOT}/docker-runtime/bin/docker-logs"

  print_written_files
  echo ""
}

# ═══ cmd_update ═══════════════════════════════════════════════════════════════

cmd_update() {
  require_root

  [ ! -f "$SANDCASTLE_HOME/.env" ] && die "No existing install found at $SANDCASTLE_HOME — run 'install' first"

  # shellcheck source=/dev/null
  source "$SANDCASTLE_HOME/.env"

  # Backfill vars that may be missing in older .env files
  grep -q '^GITHUB_CLIENT_ID=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GITHUB_CLIENT_SECRET=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GOOGLE_CLIENT_ID=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}" >> "$SANDCASTLE_HOME/.env"
  grep -q '^GOOGLE_CLIENT_SECRET=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}" >> "$SANDCASTLE_HOME/.env"

  echo ""
  echo -e "${BLUE}═══ Sandcastle Update ═══${NC}"
  echo ""
  info "Available images (${ARCH}):"
  show_image_info "sandcastle"
  show_image_info "sandcastle-sandbox"
  echo ""

  ensure_dirs

  info "Pulling images..."
  $DOCKER pull "$APP_IMAGE" &
  $DOCKER pull "$SANDBOX_IMAGE" &
  wait
  ok "Images pulled"

  write_compose
  write_helper_scripts

  info "Restarting services..."
  cd "$SANDCASTLE_HOME"
  $DOCKER compose --env-file .env up -d
  ok "Services restarted"

  echo ""
  echo -e "${GREEN}  Sandcastle updated!${NC}"

  print_written_files
  echo ""
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

case "$COMMAND" in
  gen-env)    cmd_gen_env ;;
  install)    load_env; derive_vars; cmd_install ;;
  update)     load_env; derive_vars; cmd_update ;;
  reset)      load_env; derive_vars; cmd_destroy true; cmd_install ;;
  uninstall)  load_env; derive_vars; cmd_destroy ;;
esac
