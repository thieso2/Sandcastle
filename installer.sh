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
Usage: installer.sh [COMMAND] [OPTIONS]

Sandcastle installer — sets up Docker (via Dockyard), Traefik, and the
Sandcastle platform.

Commands:
  gen-env      Generate sandcastle.env config file (default: ./sandcastle.env)
  install      Install or upgrade Sandcastle (default)
  update       Pull latest images and restart services
  reset        Tear down existing install, then reinstall
  uninstall    Remove Sandcastle completely
  help         Show this help message

install options:
  --from-backup <file>   Restore data from a backup file after installing.
                         Secrets, database, and user data are loaded from the
                         backup instead of being generated fresh.
                         SANDCASTLE_HOST is still required in sandcastle.env.
                         SANDCASTLE_ADMIN_EMAIL/PASSWORD are not required.

Environment:
  SANDCASTLE_ENV   Path to config file (default search order:
                   ./sandcastle.env → <script_dir>/sandcastle.env →
                   $SANDCASTLE_HOME/etc/sandcastle.env)

Workflow (fresh install):
  1. installer.sh gen-env              # generate config
  2. vi sandcastle.env                 # edit to taste
  3. sudo installer.sh install         # install (finds ./sandcastle.env)

Workflow (restore from backup):
  1. installer.sh gen-env              # generate config (set SANDCASTLE_HOST)
  2. vi sandcastle.env                 # set host, TLS mode — no admin password needed
  3. sudo installer.sh install --from-backup ./sandcastle-backup-*.tar.zst
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
  TCP_PORT_MIN="${SANDCASTLE_TCP_PORT_MIN:-3000}"
  TCP_PORT_MAX="${SANDCASTLE_TCP_PORT_MAX:-3099}"
  SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE:-selfsigned}"
  SANDCASTLE_ADMIN_USER="${SANDCASTLE_ADMIN_USER:-admin}"

  DOCKYARD_ROOT="${DOCKYARD_ROOT:-$SANDCASTLE_HOME/dockyard}"
  DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-sc_}"

  # Single RFC 1918 /16 from which all Sandcastle Docker networks are carved.
  # Must be a private range (10.x.x.x, 172.16-31.x.x, or 192.168.x.x).
  SANDCASTLE_PRIVATE_NET="${SANDCASTLE_PRIVATE_NET:-10.89.0.0/16}"
  _priv_base="${SANDCASTLE_PRIVATE_NET%%/*}"        # e.g. "10.89.0.0"
  _priv_prefix="${_priv_base%.*.*}"                  # e.g. "10.89"
  DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-${_priv_prefix}.0.1/24}"
  DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-${_priv_prefix}.0.0/24}"
  DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-${SANDCASTLE_PRIVATE_NET}}"
  DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

  DOCKER_SOCK="${DOCKYARD_ROOT}/run/docker.sock"
  DOCKER="${DOCKYARD_ROOT}/bin/docker"

  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

  # Resolve password from file if needed
  if [ -z "${SANDCASTLE_ADMIN_PASSWORD:-}" ] && [ -n "${SANDCASTLE_ADMIN_PASSWORD_FILE:-}" ]; then
    [ ! -f "$SANDCASTLE_ADMIN_PASSWORD_FILE" ] && die "Password file not found: $SANDCASTLE_ADMIN_PASSWORD_FILE"
    SANDCASTLE_ADMIN_PASSWORD="$(cat "$SANDCASTLE_ADMIN_PASSWORD_FILE")"
  fi
}

# ═══ setup_ssh_keys ══════════════════════════════════════════════════════
# Copy deploying user's SSH keys to sandcastle user

setup_ssh_keys() {
  local deploying_user="${SUDO_USER:-}"

  if [ -z "$deploying_user" ]; then
    warn "No SUDO_USER found — skipping SSH key setup"
    return
  fi

  local source_keys="/home/${deploying_user}/.ssh/authorized_keys"
  local target_dir="${SANDCASTLE_HOME}/.ssh"
  local target_keys="${target_dir}/authorized_keys"

  if [ ! -f "$source_keys" ]; then
    warn "No SSH keys found for user '${deploying_user}' — skipping SSH key setup"
    return
  fi

  info "Setting up SSH keys for '${SANDCASTLE_USER}'..."

  # Create .ssh directory if it doesn't exist
  mkdir -p "$target_dir"
  chmod 700 "$target_dir"
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$target_dir"

  # Copy authorized_keys
  cp "$source_keys" "$target_keys"
  chmod 600 "$target_keys"
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$target_keys"

  ok "SSH keys configured for '${SANDCASTLE_USER}'"
}

# ═══ setup_passwordless_sudo ══════════════════════════════════════════════
# Add sandcastle user to sudoers with NOPASSWD:ALL

setup_passwordless_sudo() {
  local sudoers_file="/etc/sudoers.d/sandcastle"

  info "Configuring passwordless sudo for '${SANDCASTLE_USER}'..."

  echo "${SANDCASTLE_USER} ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
  chmod 440 "$sudoers_file"

  # Validate sudoers syntax
  if ! visudo -cf "$sudoers_file" &>/dev/null; then
    rm -f "$sudoers_file"
    warn "Failed to validate sudoers file — skipping passwordless sudo setup"
    return
  fi

  wrote "$sudoers_file"
  ok "Passwordless sudo configured for '${SANDCASTLE_USER}'"
}

# ═══ setup_bashrc_path ════════════════════════════════════════════════════
# Add dockyard/bin to PATH in .profile and .bashrc (idempotent)

setup_bashrc_path() {
  local profile="${SANDCASTLE_HOME}/.profile"
  local bashrc="${SANDCASTLE_HOME}/.bashrc"
  local path_export="export PATH=${DOCKYARD_ROOT}/bin:${SANDCASTLE_HOME}/bin:\$PATH"

  info "Configuring PATH in .profile and .bashrc..."

  # Add to .profile for SSH non-interactive shells
  touch "$profile"
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$profile"

  if ! grep -qF "$path_export" "$profile" 2>/dev/null; then
    echo "$path_export" >> "$profile"
    wrote "$profile"
  fi

  # Add to .bashrc for interactive shells
  touch "$bashrc"
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$bashrc"

  if ! grep -qF "$path_export" "$bashrc" 2>/dev/null; then
    echo "$path_export" >> "$bashrc"
    wrote "$bashrc"
  fi

  ok "PATH configured in .profile and .bashrc"
}

# ═══ install_prerequisites ════════════════════════════════════════════════════
# Install required host tools for the installer and embedded Dockyard runtime.

install_prerequisites() {
  local missing=()
  command -v curl >/dev/null 2>&1     || missing+=("curl")
  command -v iptables >/dev/null 2>&1 || missing+=("iptables")
  command -v rsync >/dev/null 2>&1    || missing+=("rsync")
  command -v zstd >/dev/null 2>&1     || missing+=("zstd")
  if [ ${#missing[@]} -gt 0 ]; then
    info "Installing prerequisites: ${missing[*]}..."
    apt-get update >/dev/null
    apt-get install -y "${missing[@]}" >/dev/null \
      || die "Failed to install required prerequisites: ${missing[*]}"
    ok "Prerequisites installed: ${missing[*]}"
  fi
}

# ═══ write_admin_script ═══════════════════════════════════════════════════════
# Install sandcastle-admin to $SANDCASTLE_HOME/bin/

write_admin_script() {
  local bin_dir="$SANDCASTLE_HOME/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/sandcastle-admin" <<'__ADMIN_EOF__'
#!/bin/bash
# sandcastle-admin — Sandcastle backup/restore administration tool
# Usage: sandcastle-admin <command> [options]
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

# ═══ Config ══════════════════════════════════════════════════════════════════

SANDCASTLE_HOME="${SANDCASTLE_HOME:-/sandcastle}"

# Load installed env
ENV_FILE="$SANDCASTLE_HOME/etc/sandcastle.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

DOCKYARD_ROOT="${DOCKYARD_ROOT:-$SANDCASTLE_HOME/dockyard}"
DOCKER="${DOCKYARD_ROOT}/bin/docker"

# Fallback: check legacy docker-runtime layout for older installs
if [ ! -x "$DOCKER" ] && [ -x "$SANDCASTLE_HOME/docker-runtime/bin/docker" ]; then
  DOCKER="$SANDCASTLE_HOME/docker-runtime/bin/docker"
fi
COMPOSE_FILE="$SANDCASTLE_HOME/docker-compose.yml"

[ -x "$DOCKER" ] || die "Docker not found at $DOCKER — is Sandcastle installed?"
[ -f "$COMPOSE_FILE" ] || die "docker-compose.yml not found at $COMPOSE_FILE — is Sandcastle installed?"

# ═══ BTRFS helpers ═══════════════════════════════════════════════════════════

is_btrfs() {
  stat -f --format="%T" "$1" 2>/dev/null | grep -qi btrfs
}

btrfs_snapshot_r() {
  btrfs subvolume snapshot -r "$1" "$2" 2>/dev/null
}

btrfs_delete() {
  btrfs subvolume delete "$1" 2>/dev/null || rm -rf "$1"
}

# ═══ cmd_backup ══════════════════════════════════════════════════════════════

cmd_backup() {
  local output=""
  local skip_sandbox_volumes=false
  local skip_snapshot_images=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|-o)
        output="$2"
        shift 2
        ;;
      --no-sandbox-volumes)
        skip_sandbox_volumes=true
        shift
        ;;
      --no-snapshot-images)
        skip_snapshot_images=true
        shift
        ;;
      *)
        die "Unknown option: $1 (run 'sandcastle-admin help' for usage)"
        ;;
    esac
  done

  command -v zstd >/dev/null 2>&1 || die "zstd not found — install: apt-get install zstd"
  command -v rsync >/dev/null 2>&1 || die "rsync not found — install: apt-get install rsync"

  # Get app version from the running web container (fall back gracefully)
  local version
  version=$($DOCKER compose -f "$COMPOSE_FILE" exec -T web \
    ./bin/rails runner "puts Sandcastle::VERSION rescue puts '0.0.0'" 2>/dev/null \
    | tail -1 || echo "unknown")
  version="${version:-unknown}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%d_%H%M%S")
  local default_output="./sandcastle-backup-${timestamp}-${version}.tar.zst"
  output="${output:-$default_output}"

  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '$work_dir'" EXIT

  local backup_dir="$work_dir/sandcastle-backup"
  mkdir -p "$backup_dir"/{db,secrets,data}

  echo ""
  echo -e "${BLUE}═══ Sandcastle Backup ═══${NC}"
  echo ""
  info "Output: $output"
  echo ""

  # ── Dump PostgreSQL databases ─────────────────────────────────────────────

  info "Dumping PostgreSQL databases..."
  local db
  for db in sandcastle_production sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable; do
    info "  pg_dump $db..."
    $DOCKER compose -f "$COMPOSE_FILE" exec -T postgres \
      pg_dump -U sandcastle --format=custom "$db" \
      > "$backup_dir/db/${db}.pgdump"
    ok "  ${db}.pgdump"
  done

  # ── Secrets ───────────────────────────────────────────────────────────────

  info "Backing up secrets..."
  local rails_secrets="$SANDCASTLE_HOME/data/rails/.secrets"
  local postgres_secrets="$SANDCASTLE_HOME/data/postgres/.secrets"

  if [ -f "$rails_secrets" ]; then
    cp "$rails_secrets" "$backup_dir/secrets/rails.secrets"
    ok "  rails.secrets"
  else
    warn "  Rails secrets not found at $rails_secrets"
  fi

  if [ -f "$postgres_secrets" ]; then
    cp "$postgres_secrets" "$backup_dir/secrets/postgres.secrets"
    ok "  postgres.secrets"
  else
    warn "  Postgres secrets not found at $postgres_secrets"
  fi

  # Let's Encrypt cert (nice-to-have)
  local acme_json="$SANDCASTLE_HOME/data/traefik/acme.json"
  if [ -f "$acme_json" ] && [ -s "$acme_json" ]; then
    cp "$acme_json" "$backup_dir/secrets/acme.json"
    ok "  acme.json"
  fi

  # ── User data ─────────────────────────────────────────────────────────────

  info "Backing up user data..."
  mkdir -p "$backup_dir/data/users"
  if [ -d "$SANDCASTLE_HOME/data/users" ]; then
    if is_btrfs "$SANDCASTLE_HOME/data/users"; then
      local snap_users="$SANDCASTLE_HOME/data/.backup-snap-users-$$"
      btrfs_snapshot_r "$SANDCASTLE_HOME/data/users" "$snap_users"
      rsync -a --exclude='*/home/.docker' "$snap_users/" "$backup_dir/data/users/"
      btrfs_delete "$snap_users"
    else
      rsync -a --exclude='*/home/.docker' "$SANDCASTLE_HOME/data/users/" "$backup_dir/data/users/"
    fi
    ok "  users/"
  fi

  # ── Sandbox volumes ───────────────────────────────────────────────────────

  if [ "$skip_sandbox_volumes" = false ]; then
    info "Backing up sandbox volumes..."
    mkdir -p "$backup_dir/data/sandboxes"
    if [ -d "$SANDCASTLE_HOME/data/sandboxes" ]; then
      if is_btrfs "$SANDCASTLE_HOME/data/sandboxes"; then
        local snap_sandboxes="$SANDCASTLE_HOME/data/.backup-snap-sandboxes-$$"
        btrfs_snapshot_r "$SANDCASTLE_HOME/data/sandboxes" "$snap_sandboxes"
        rsync -a "$snap_sandboxes/" "$backup_dir/data/sandboxes/"
        btrfs_delete "$snap_sandboxes"
      else
        rsync -a "$SANDCASTLE_HOME/data/sandboxes/" "$backup_dir/data/sandboxes/"
      fi
      ok "  sandboxes/"
    fi
  else
    info "Skipping sandbox volumes (--no-sandbox-volumes)"
  fi

  # ── Snapshot dirs ─────────────────────────────────────────────────────────

  if [ -d "$SANDCASTLE_HOME/data/snapshots" ]; then
    info "Backing up snapshot directories..."
    mkdir -p "$backup_dir/data/snapshots"
    rsync -a "$SANDCASTLE_HOME/data/snapshots/" "$backup_dir/data/snapshots/"
    ok "  snapshots/"
  fi

  # ── Snapshot Docker images ────────────────────────────────────────────────

  if [ "$skip_snapshot_images" = false ]; then
    local snap_images
    snap_images=$($DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | grep '^sc-snap-' || true)
    if [ -n "$snap_images" ]; then
      info "Saving snapshot Docker images..."
      mkdir -p "$backup_dir/images"
      local img fname
      while IFS= read -r img; do
        fname=$(echo "$img" | tr '/:' '-').tar
        info "  docker save $img..."
        $DOCKER save "$img" > "$backup_dir/images/$fname"
        ok "  $fname"
      done <<< "$snap_images"
    fi
  else
    info "Skipping snapshot images (--no-snapshot-images)"
  fi

  # ── Manifest ──────────────────────────────────────────────────────────────

  local user_count sandbox_count snapshot_count
  user_count=$(find "$SANDCASTLE_HOME/data/users" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)
  sandbox_count=$(find "$SANDCASTLE_HOME/data/sandboxes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)
  snapshot_count=$(find "$SANDCASTLE_HOME/data/snapshots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)

  local includes='"db","secrets","user_data"'
  [ "$skip_sandbox_volumes" = false ] && includes="$includes,\"sandbox_volumes\""
  [ -d "$SANDCASTLE_HOME/data/snapshots" ] && includes="$includes,\"snapshot_dirs\""
  [ "$skip_snapshot_images" = false ] && includes="$includes,\"snapshot_images\""

  cat > "$backup_dir/manifest.json" <<MANIFEST
{
  "version": "${version}",
  "schema_version": 1,
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "hostname": "$(hostname)",
  "includes": [${includes}],
  "user_count": ${user_count},
  "sandbox_count": ${sandbox_count},
  "snapshot_count": ${snapshot_count}
}
MANIFEST

  # ── Create archive ────────────────────────────────────────────────────────

  info "Creating archive..."
  tar --use-compress-program=zstd -cf "$output" -C "$work_dir" sandcastle-backup

  local size
  size=$(du -sh "$output" 2>/dev/null | cut -f1 || echo "?")

  echo ""
  ok "Backup complete: $output (${size})"
  echo ""
}

# ═══ cmd_restore ══════════════════════════════════════════════════════════════

cmd_restore() {
  local backup_file=""
  local skip_db=false
  local skip_data=false
  local skip_images=false
  local yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-db)     skip_db=true; shift ;;
      --skip-data)   skip_data=true; shift ;;
      --skip-images) skip_images=true; shift ;;
      --yes|-y)      yes=true; shift ;;
      -*)            die "Unknown option: $1 (run 'sandcastle-admin help' for usage)" ;;
      *)             backup_file="$1"; shift ;;
    esac
  done

  [ -n "$backup_file" ] || die "Usage: sandcastle-admin restore <backup-file.tar.zst> [options]"
  [ -f "$backup_file" ] || die "Backup file not found: $backup_file"

  command -v zstd >/dev/null 2>&1 || die "zstd not found — install: apt-get install zstd"

  # ── Read and validate manifest ────────────────────────────────────────────

  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '$work_dir'" EXIT

  info "Reading backup manifest..."
  tar --use-compress-program=zstd -xf "$backup_file" -C "$work_dir" \
    sandcastle-backup/manifest.json 2>/dev/null \
    || die "Cannot read manifest — is this a valid Sandcastle backup file?"

  local manifest="$work_dir/sandcastle-backup/manifest.json"

  # Parse with python3 (always available on Ubuntu)
  local bk_version bk_created bk_hostname bk_schema bk_users bk_sandboxes bk_snapshots
  bk_version=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('version','?'))")
  bk_created=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('created_at','?'))")
  bk_hostname=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('hostname','?'))")
  bk_schema=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('schema_version',1))")
  bk_users=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('user_count',0))")
  bk_sandboxes=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('sandbox_count',0))")
  bk_snapshots=$(python3 -c "import json; d=json.load(open('$manifest')); print(d.get('snapshot_count',0))")

  if [ "${bk_schema}" -gt 1 ] 2>/dev/null; then
    warn "Backup schema_version=${bk_schema} is newer than supported (1) — proceeding anyway"
  fi

  echo ""
  echo -e "${BLUE}═══ Sandcastle Restore ═══${NC}"
  echo ""
  echo -e "  Backup version:  ${YELLOW}${bk_version}${NC}"
  echo -e "  Created:         ${bk_created}"
  echo -e "  Source host:     ${bk_hostname}"
  echo -e "  Users:           ${bk_users}"
  echo -e "  Sandboxes:       ${bk_sandboxes}"
  echo -e "  Snapshots:       ${bk_snapshots}"
  echo ""
  echo -e "${YELLOW}WARNING: This will overwrite all current Sandcastle data!${NC}"
  echo ""

  if [ "$yes" != true ]; then
    read -rp "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || die "Aborted"
  fi

  # ── Step 1: Stop Sandcastle ───────────────────────────────────────────────

  info "Step 1/7: Stopping Sandcastle..."
  cd "$SANDCASTLE_HOME"
  $DOCKER compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  ok "Services stopped"

  # ── Extract backup archive ────────────────────────────────────────────────

  info "Extracting backup archive..."
  tar --use-compress-program=zstd -xf "$backup_file" -C "$work_dir"
  local bk_dir="$work_dir/sandcastle-backup"

  # ── Step 2: Restore secrets ───────────────────────────────────────────────

  info "Step 2/7: Restoring secrets..."

  local main_env="$SANDCASTLE_HOME/.env"

  if [ -f "$bk_dir/secrets/rails.secrets" ]; then
    mkdir -p "$SANDCASTLE_HOME/data/rails"
    cp "$bk_dir/secrets/rails.secrets" "$SANDCASTLE_HOME/data/rails/.secrets"
    chmod 600 "$SANDCASTLE_HOME/data/rails/.secrets"
    # Inject AR keys into .env
    set -a
    # shellcheck source=/dev/null
    source "$bk_dir/secrets/rails.secrets"
    set +a
    local key val
    for key in AR_ENCRYPTION_PRIMARY_KEY AR_ENCRYPTION_DETERMINISTIC_KEY AR_ENCRYPTION_KEY_DERIVATION_SALT; do
      val="${!key:-}"
      if [ -n "$val" ]; then
        if grep -q "^${key}=" "$main_env" 2>/dev/null; then
          sed -i "s|^${key}=.*|${key}=${val}|" "$main_env"
        else
          echo "${key}=${val}" >> "$main_env"
        fi
      fi
    done
    ok "  rails.secrets"
  fi

  if [ -f "$bk_dir/secrets/postgres.secrets" ]; then
    mkdir -p "$SANDCASTLE_HOME/data/postgres"
    cp "$bk_dir/secrets/postgres.secrets" "$SANDCASTLE_HOME/data/postgres/.secrets"
    chmod 600 "$SANDCASTLE_HOME/data/postgres/.secrets"
    set -a
    # shellcheck source=/dev/null
    source "$bk_dir/secrets/postgres.secrets"
    set +a
    if [ -n "${DB_PASSWORD:-}" ]; then
      if grep -q "^DB_PASSWORD=" "$main_env" 2>/dev/null; then
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" "$main_env"
      else
        echo "DB_PASSWORD=${DB_PASSWORD}" >> "$main_env"
      fi
    fi
    ok "  postgres.secrets"
  fi

  if [ -f "$bk_dir/secrets/acme.json" ]; then
    mkdir -p "$SANDCASTLE_HOME/data/traefik"
    cp "$bk_dir/secrets/acme.json" "$SANDCASTLE_HOME/data/traefik/acme.json"
    chmod 600 "$SANDCASTLE_HOME/data/traefik/acme.json"
    ok "  acme.json"
  fi

  # Reload .env so subsequent docker compose picks up updated secrets
  set -a
  # shellcheck source=/dev/null
  source "$main_env"
  set +a

  # ── Step 3 & 4: Database restore ──────────────────────────────────────────

  if [ "$skip_db" = false ]; then
    info "Step 3/7: Starting PostgreSQL..."
    $DOCKER compose -f "$COMPOSE_FILE" up -d postgres
    local i
    for i in $(seq 1 30); do
      $DOCKER compose -f "$COMPOSE_FILE" exec -T postgres \
        pg_isready -U sandcastle -d sandcastle_production &>/dev/null && break
      sleep 2
    done
    ok "PostgreSQL ready"

    info "Step 4/7: Restoring databases..."
    local db dump
    for db in sandcastle_production sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable; do
      dump="$bk_dir/db/${db}.pgdump"
      if [ -f "$dump" ]; then
        info "  Restoring $db..."
        # Ensure the database exists (for cache/queue/cable on first restore)
        $DOCKER compose -f "$COMPOSE_FILE" exec -T postgres \
          psql -U sandcastle -d postgres \
          -c "SELECT 1 FROM pg_database WHERE datname='${db}'" \
          | grep -q "1 row" \
          || $DOCKER compose -f "$COMPOSE_FILE" exec -T postgres \
               createdb -U sandcastle "$db" 2>/dev/null || true
        $DOCKER compose -f "$COMPOSE_FILE" exec -T postgres \
          pg_restore -U sandcastle -d "$db" --clean --if-exists < "$dump" 2>/dev/null || true
        ok "  $db"
      else
        warn "  No dump found for $db — skipping"
      fi
    done
  else
    info "Step 3/7: Skipping database (--skip-db)"
    info "Step 4/7: Skipping database (--skip-db)"
  fi

  # ── Step 5: Run migrations ────────────────────────────────────────────────

  info "Step 5/7: Running migrations..."
  $DOCKER compose -f "$COMPOSE_FILE" run --rm migrate 2>/dev/null \
    || warn "Migrate service not available — run 'rails db:migrate' manually if needed"
  ok "Migrations done"

  # ── Step 6: Restore filesystem data ──────────────────────────────────────

  if [ "$skip_data" = false ]; then
    info "Step 6/7: Restoring filesystem data..."

    if [ -d "$bk_dir/data/users" ]; then
      mkdir -p "$SANDCASTLE_HOME/data/users"
      rsync -a --delete "$bk_dir/data/users/" "$SANDCASTLE_HOME/data/users/"
      ok "  users/"
    fi

    if [ -d "$bk_dir/data/sandboxes" ]; then
      mkdir -p "$SANDCASTLE_HOME/data/sandboxes"
      rsync -a --delete "$bk_dir/data/sandboxes/" "$SANDCASTLE_HOME/data/sandboxes/"
      ok "  sandboxes/"
    fi

    if [ -d "$bk_dir/data/snapshots" ]; then
      mkdir -p "$SANDCASTLE_HOME/data/snapshots"
      rsync -a --delete "$bk_dir/data/snapshots/" "$SANDCASTLE_HOME/data/snapshots/"
      ok "  snapshots/"
    fi
  else
    info "Step 6/7: Skipping filesystem data (--skip-data)"
  fi

  # ── Step 7: Load snapshot Docker images ───────────────────────────────────

  if [ "$skip_images" = false ] && [ -d "$bk_dir/images" ]; then
    info "Step 7/7: Loading snapshot Docker images..."
    local img_tar
    for img_tar in "$bk_dir/images/"*.tar; do
      [ -f "$img_tar" ] || continue
      info "  Loading $(basename "$img_tar")..."
      $DOCKER load < "$img_tar"
      ok "  $(basename "$img_tar")"
    done
  else
    info "Step 7/7: Skipping snapshot images"
  fi

  # ── Start Sandcastle ───────────────────────────────────────────────────────

  info "Starting Sandcastle..."
  cd "$SANDCASTLE_HOME"
  $DOCKER compose -f "$COMPOSE_FILE" up -d
  ok "Sandcastle started"

  echo ""
  ok "Restore complete!"
  echo ""
}

# ═══ cmd_update ═══════════════════════════════════════════════════════════════

cmd_update() {
  local app_image="${APP_IMAGE:-ghcr.io/thieso2/sandcastle:latest}"
  local sandbox_image="${SANDBOX_IMAGE:-ghcr.io/thieso2/sandcastle-sandbox:latest}"

  echo ""
  echo -e "${BLUE}═══ Sandcastle Update ═══${NC}"
  echo ""

  info "Pulling images..."
  info "  App:     $app_image"
  info "  Sandbox: $sandbox_image"
  $DOCKER pull "$app_image" &
  $DOCKER pull "$sandbox_image" &
  wait
  ok "Images pulled"

  info "Restarting services..."
  cd "$SANDCASTLE_HOME"
  $DOCKER compose -f "$COMPOSE_FILE" up -d
  ok "Services restarted"

  echo ""
  echo -e "${GREEN}  Sandcastle updated!${NC}"
  echo ""
}

# ═══ Help ════════════════════════════════════════════════════════════════════

cmd_help() {
  cat <<'USAGE'
Usage: sandcastle-admin <command> [options]

Commands:
  backup     Create a full backup of this Sandcastle instance
  restore    Restore a Sandcastle instance from a backup file
  update     Pull latest app & sandbox images and restart services
  help       Show this help message

backup [options]:
  --output <path>           Output path (default: ./sandcastle-backup-<ts>-<ver>.tar.zst)
  --no-sandbox-volumes      Skip /data/sandboxes/*/vol (faster/smaller)
  --no-snapshot-images      Skip docker save of snapshot images

restore <file.tar.zst> [options]:
  --skip-db                 Skip database restore
  --skip-data               Skip filesystem data restore
  --skip-images             Skip loading snapshot Docker images
  --yes, -y                 Skip confirmation prompt

Examples:
  sandcastle-admin backup
  sandcastle-admin backup --output /mnt/backups/sc.tar.zst --no-snapshot-images
  sandcastle-admin restore /mnt/backups/sandcastle-backup-2026-03-01.tar.zst
  sandcastle-admin restore /mnt/backups/sc.tar.zst --skip-db --yes
  sandcastle-admin update
USAGE
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  backup)         cmd_backup "$@" ;;
  restore)        cmd_restore "$@" ;;
  update)         cmd_update ;;
  help|-h|--help) cmd_help ;;
  *) die "Unknown command: $COMMAND — run 'sandcastle-admin help'" ;;
esac
__ADMIN_EOF__

  chmod +x "$bin_dir/sandcastle-admin"
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$bin_dir/sandcastle-admin"
  wrote "$bin_dir/sandcastle-admin"
  ok "sandcastle-admin installed to $bin_dir"
}

# ═══ setup_login_banner ══════════════════════════════════════════════════
# Create a login banner showing Sandcastle version and info

setup_login_banner() {
  local profile_d="/etc/profile.d/sandcastle-banner.sh"

  info "Setting up login banner..."

  cat > "$profile_d" <<'BANNER_SCRIPT'
#!/bin/bash
# Sandcastle login banner

# Only show on interactive shells
[[ $- == *i* ]] || return 0

# Skip if already shown in this session
[[ -n "${SANDCASTLE_BANNER_SHOWN:-}" ]] && return 0
export SANDCASTLE_BANNER_SHOWN=1

# Get version from image build metadata
if [ -f /etc/sandcastle-version ]; then
  VERSION=$(cat /etc/sandcastle-version)
else
  VERSION="unknown"
fi

cat << 'EOF'

  ███████╗ █████╗ ███╗   ██╗██████╗  ██████╗ █████╗ ███████╗████████╗██╗     ███████╗
  ██╔════╝██╔══██╗████╗  ██║██╔══██╗██╔════╝██╔══██╗██╔════╝╚══██╔══╝██║     ██╔════╝
  ███████╗███████║██╔██╗ ██║██║  ██║██║     ███████║███████╗   ██║   ██║     █████╗
  ╚════██║██╔══██║██║╚██╗██║██║  ██║██║     ██╔══██║╚════██║   ██║   ██║     ██╔══╝
  ███████║██║  ██║██║ ╚████║██████╔╝╚██████╗██║  ██║███████║   ██║   ███████╗███████╗
  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚══════╝

EOF

echo "  Version: ${VERSION}"
echo "  Docs:    https://github.com/thieso2/Sandcastle"
echo ""
BANNER_SCRIPT

  chmod +x "$profile_d"
  wrote "$profile_d"
  ok "Login banner configured"
}

# ═══ setup_network_isolation ══════════════════════════════════════════════
# Write infra container IPs to isolation.d/infra.rules and restart the
# dockyard service so its ExecStartPost picks up the rules.
# Must be called AFTER docker-compose is up (so infra container IPs are known).
# Chain creation and iptables management is handled by dockyard (v0.1.1+).

setup_network_isolation() {
  local isolation_dir="${DOCKYARD_ROOT}/etc/isolation.d"
  local rules_file="${isolation_dir}/infra.rules"

  # Derive fixed infra IPs from the sandcastle-web network subnet.
  # These match the ipv4_address values in docker-compose.yml (.10-.13).
  local net_subnet
  net_subnet=$($DOCKER network inspect sandcastle-web \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null) || true

  if [ -z "$net_subnet" ]; then
    warn "sandcastle-web network not found — skipping isolation rules"
    return
  fi

  local net_prefix="${net_subnet%.*}"

  mkdir -p "$isolation_dir"
  cat > "$rules_file" <<RULES
# Fixed IPs of infrastructure containers on sandcastle-web (${net_subnet})
# traefik
${net_prefix}.10
# postgres
${net_prefix}.11
# web
${net_prefix}.12
# worker
${net_prefix}.13
RULES
  wrote "$rules_file"

  # Restart dockyard service to apply isolation rules via ExecStartPost
  local service_name="${DOCKYARD_DOCKER_PREFIX}docker"
  if systemctl is-active "$service_name" &>/dev/null; then
    systemctl restart "$service_name"
    ok "Cross-tenant network isolation configured (via dockyard service restart)"
  else
    warn "Dockyard service ${service_name} not running — isolation rules will apply on next start"
  fi
}

# ═══ ensure_dirs ═════════════════════════════════════════════════════════
# Create/fix data directories and ownership. Safe to run repeatedly.

ensure_dirs() {
  mkdir -p "$SANDCASTLE_HOME"/etc
  mkdir -p "$SANDCASTLE_HOME"/bin
  mkdir -p "$SANDCASTLE_HOME"/data/{users,sandboxes,wetty,postgres,snapshots}
  mkdir -p "$SANDCASTLE_HOME"/data/traefik/{dynamic,certs}
  chown "${SANDCASTLE_USER}:${SANDCASTLE_GROUP}" "$SANDCASTLE_HOME"
  # Own top-level data dirs (not -R: per-user subdirs are bind-mounted into
  # Sysbox containers which use a different UID range via /etc/subuid).
  chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" \
    "$SANDCASTLE_HOME"/data/users \
    "$SANDCASTLE_HOME"/data/sandboxes \
    "$SANDCASTLE_HOME"/data/snapshots \
    "$SANDCASTLE_HOME"/data/wetty
  chown -R "${SANDCASTLE_UID}:${SANDCASTLE_GID}" \
    "$SANDCASTLE_HOME"/data/traefik/dynamic
  # Per-user dirs: own the user-level parent and all direct children so the
  # Rails container (UID $SANDCASTLE_UID) can create subdirectories.
  # Then chmod 777 the bind-mount targets so Sysbox-mapped root can write.
  for d in "$SANDCASTLE_HOME"/data/users/*; do
    if [ -d "$d" ]; then
      chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" "$d"
      # Also fix any direct children (home, data, tailscale, etc.)
      find "$d" -maxdepth 1 -mindepth 1 -type d \
        -exec chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" {} +
    fi
  done
  for d in "$SANDCASTLE_HOME"/data/users/*/home \
           "$SANDCASTLE_HOME"/data/users/*/data \
           "$SANDCASTLE_HOME"/data/sandboxes/*/vol; do
    [ -d "$d" ] && chmod 777 "$d"
  done
  # Fix home dir permissions inside running sandbox containers so sshd
  # StrictModes is satisfied (rejects 777 home dirs).
  for cid in $($DOCKER ps -q 2>/dev/null); do
    user=$($DOCKER inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" \
      | grep '^SANDCASTLE_USER=' | cut -d= -f2 || true)
    [ -n "$user" ] && $DOCKER exec "$cid" chmod 755 "/home/$user" 2>/dev/null || true
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

pick_private_net() {
  # Pick a random 10.X.0.0/16 not already routed on this host.
  local used_octets
  used_octets=$(
    { ip route 2>/dev/null; ip addr 2>/dev/null; } \
      | grep -oE '10\.[0-9]+\.' \
      | grep -oE '\.[0-9]+\.' \
      | tr -d '.' \
      | sort -un
  )
  for b in $(shuf -i 1-254 2>/dev/null || python3 -c "import random,sys; l=list(range(1,255)); random.shuffle(l); print('\n'.join(map(str,l)))"); do
    if ! echo "$used_octets" | grep -qx "$b"; then
      echo "10.${b}.0.0/16"
      return
    fi
  done
  # Fallback
  echo "10.$(shuf -i 1-254 -n1 2>/dev/null || echo 89).0.0/16"
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

install_mkcert() {
  if command -v mkcert &>/dev/null; then
    return 0
  fi
  info "Installing mkcert..."
  local arch
  arch=$(uname -m)
  local mkcert_arch
  case "$arch" in
    x86_64)  mkcert_arch="amd64" ;;
    aarch64) mkcert_arch="arm64" ;;
    *)       die "Unsupported architecture for mkcert: $arch" ;;
  esac
  curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/${mkcert_arch}" \
    -o /usr/local/bin/mkcert
  chmod +x /usr/local/bin/mkcert
  ok "mkcert installed"
}

# ═══ write_compose ══════════════════════════════════════════════════════════

# Write the bundled dockyard.sh to /tmp so it can be invoked without wget.
write_dockyard_sh() {
  cat > /tmp/dockyard.sh <<'__DOCKYARD_BUNDLED_EOF__'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Env loading ──────────────────────────────────────────────

LOADED_ENV_FILE=""

# Returns 0 on success, 1 if no config file exists.
# Exits immediately if DOCKYARD_ENV is set but the file is missing.
try_load_env() {
    local script_env="${SCRIPT_DIR}/../etc/dockyard.env"
    local root_env="${DOCKYARD_ROOT:-/dockyard}/etc/dockyard.env"

    if [ -n "${DOCKYARD_ENV:-}" ]; then
        if [ ! -f "$DOCKYARD_ENV" ]; then
            echo "Error: DOCKYARD_ENV file not found: ${DOCKYARD_ENV}" >&2
            exit 1
        fi
        LOADED_ENV_FILE="$(cd "$(dirname "$DOCKYARD_ENV")" && pwd)/$(basename "$DOCKYARD_ENV")"
    elif [ -f "./dockyard.env" ]; then
        LOADED_ENV_FILE="$(pwd)/dockyard.env"
    elif [ -f "$script_env" ]; then
        LOADED_ENV_FILE="$(cd "$(dirname "$script_env")" && pwd)/$(basename "$script_env")"
    elif [ -f "$root_env" ]; then
        LOADED_ENV_FILE="$root_env"
    else
        return 1
    fi

    echo "Loading ${LOADED_ENV_FILE}..."
    set -a; source "$LOADED_ENV_FILE"; set +a
}

load_env() {
    if ! try_load_env; then
        echo "Error: No config found." >&2
        echo "Run './dockyard.sh gen-env' to generate one, or set DOCKYARD_ENV." >&2
        exit 1
    fi
}

derive_vars() {
    DOCKYARD_ROOT="${DOCKYARD_ROOT:-/dockyard}"
    DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-172.30.0.1/24}"
    DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-172.30.0.0/24}"
    DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-172.31.0.0/16}"
    DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

    BIN_DIR="${DOCKYARD_ROOT}/bin"
    ETC_DIR="${DOCKYARD_ROOT}/etc"
    LOG_DIR="${DOCKYARD_ROOT}/log"
    RUN_DIR="${DOCKYARD_ROOT}/run"
    BRIDGE="${DOCKYARD_DOCKER_PREFIX}docker0"
    SERVICE_NAME="${DOCKYARD_DOCKER_PREFIX}docker"
    DOCKER_SOCKET="${DOCKYARD_ROOT}/run/docker.sock"
    CONTAINERD_SOCKET="${DOCKYARD_ROOT}/run/containerd/containerd.sock"
    DOCKER_DATA="${DOCKYARD_ROOT}/lib/docker"
    DOCKER_CONFIG_DIR="${DOCKYARD_ROOT}/lib/docker-config"

    # Per-instance system user and group (socket ownership + access control)
    INSTANCE_USER="${DOCKYARD_DOCKER_PREFIX}docker"
    INSTANCE_GROUP="${DOCKYARD_DOCKER_PREFIX}docker"

    # Per-instance sysbox daemons (separate sysbox-mgr + sysbox-fs per installation)
    SYSBOX_RUN_DIR="${DOCKYARD_ROOT}/run/sysbox"
    SYSBOX_DATA_DIR="${DOCKYARD_ROOT}/lib/sysbox"
}

# ── Helpers ──────────────────────────────────────────────────

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: must run as root (use sudo)" >&2
        exit 1
    fi
}

stop_daemon() {
    local name="$1"
    local pidfile="$2"
    local timeout="${3:-10}"

    if [ ! -f "$pidfile" ]; then
        echo "${name}: no pid file"
        return 0
    fi

    local pid
    pid=$(cat "$pidfile")

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "${name}: not running (stale pid ${pid})"
        rm -f "$pidfile"
        return 0
    fi

    echo "Stopping ${name} (pid ${pid})..."
    kill "$pid"

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "  ${name} did not stop in ${timeout}s — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
            break
        fi
    done

    rm -f "$pidfile"
    echo "  ${name} stopped"
}

cleanup_pool_bridges() {
    # Remove leftover kernel bridge interfaces (br-*) whose IP falls within
    # DOCKYARD_POOL_BASE. When dockerd exits, it does not clean up user-defined
    # network bridges. Left behind, they cause "overlaps with existing routes"
    # errors on the next install because the pool CIDR is still in the routing table.
    local pool_base="${DOCKYARD_POOL_BASE:-}"
    [ -n "$pool_base" ] || return 0

    # Extract the first two octets of the pool base (e.g. "10.89" from "10.89.0.0/16")
    local pool_prefix
    pool_prefix=$(echo "$pool_base" | grep -oP '^\d+\.\d+')

    local removed=0
    while IFS= read -r iface; do
        [[ "$iface" == br-* ]] || continue
        local iface_ip
        iface_ip=$(ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
        if [[ -n "$iface_ip" && "$iface_ip" == ${pool_prefix}.* ]]; then
            echo "Removing leftover pool bridge: ${iface} (${iface_ip})"
            ip link set "$iface" down 2>/dev/null || true
            ip link delete "$iface" 2>/dev/null || true
            removed=$((removed + 1))
        fi
    done < <(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:@]+')

    [ "$removed" -gt 0 ] || true
}

# Detect the backing filesystem type for the given data directory.
# Returns the fstype string (e.g., "ext4", "zfs", "xfs").
detect_backing_fs() {
    local data_dir="$1"

    # Walk up to the nearest existing directory
    local check_dir="$data_dir"
    while [ ! -d "$check_dir" ]; do
        check_dir="$(dirname "$check_dir")"
    done

    df --output=fstype "$check_dir" 2>/dev/null | tail -1 | tr -d '[:space:]'
}

# Detect the optimal Docker storage driver for the given data directory.
# Always returns "overlay2" — sysbox-runc does not support ZFS as a container
# rootfs filesystem (fails with "unknown fs"). overlay2 works on ZFS 2.2+ and
# on all other common Linux filesystems.
# Can be overridden with DOCKYARD_STORAGE_DRIVER for future use.
detect_storage_driver() {
    local data_dir="$1"

    # Manual override
    if [ -n "${DOCKYARD_STORAGE_DRIVER:-}" ]; then
        case "$DOCKYARD_STORAGE_DRIVER" in
            auto)   ;; # fall through to detection
            overlay2|zfs)
                echo "$DOCKYARD_STORAGE_DRIVER"
                return
                ;;
            *)
                echo "Error: unsupported DOCKYARD_STORAGE_DRIVER=${DOCKYARD_STORAGE_DRIVER} (use auto, overlay2, or zfs)" >&2
                exit 1
                ;;
        esac
    fi

    # sysbox requires overlay2 — it does not recognize ZFS rootfs.
    # overlay2 works on ZFS 2.2+ with overlayfs kernel support.
    echo "overlay2"
}

# Detect the host's upstream DNS resolvers for embedding into daemon.json.
# Fixes https://github.com/thieso2/dockyard/issues/19: on hosts where
# /etc/resolv.conf points at 127.0.0.53 (systemd-resolved), Docker detects
# loopback-only resolvers and falls back to hardcoded 8.8.8.8 / 8.8.4.4.
# Environments that block public DNS (e.g. Hetzner) then see silent DNS
# failure inside containers.
#
# Lookup order:
#   1. DOCKYARD_DNS env override (space- or comma-separated IPs)
#   2. resolvectl dns (systemd-resolved authoritative source)
#   3. /run/systemd/resolve/resolv.conf (real upstreams when resolved is used)
#   4. /etc/resolv.conf (whatever is there, loopback filtered out)
#
# Loopback (127.0.0.0/8) and link-local (169.254.0.0/16) entries are stripped.
# Returns a space-separated list on stdout, or empty string when nothing is
# available (caller then omits the "dns" key from daemon.json so Docker uses
# its own defaults).
detect_upstream_dns() {
    local raw=""

    if [ -n "${DOCKYARD_DNS:-}" ]; then
        raw="${DOCKYARD_DNS//,/ }"
    elif command -v resolvectl &>/dev/null; then
        # resolvectl dns prints "Global: 1.1.1.1 8.8.8.8" and per-link lines.
        # Extract every IP-shaped token from all lines.
        raw=$(resolvectl dns 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')
    fi

    if [ -z "$raw" ] && [ -f /run/systemd/resolve/resolv.conf ]; then
        raw=$(awk '/^nameserver/ {print $2}' /run/systemd/resolve/resolv.conf | tr '\n' ' ')
    fi

    if [ -z "$raw" ] && [ -f /etc/resolv.conf ]; then
        raw=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ')
    fi

    local ip out=""
    for ip in $raw; do
        case "$ip" in
            127.*|169.254.*|::1|fe80:*) continue ;;
        esac
        out="${out}${ip} "
    done
    echo "${out% }"
}

wait_for_file() {
    local file="$1"
    local label="$2"
    local timeout="${3:-30}"
    local i=0
    while [ ! -S "$file" ]; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "Error: $label did not become ready within ${timeout}s" >&2
            return 1
        fi
    done
}

# ── Collision checks ─────────────────────────────────────────

check_prefix_conflict() {
    local prefix="${1:-$DOCKYARD_DOCKER_PREFIX}"
    local bridge="${prefix}docker0"
    local docker_service="${prefix}docker.service"
    local sysbox_service="${prefix}sysbox.service"

    if ip link show "$bridge" &>/dev/null; then
        echo "Error: Bridge ${bridge} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$docker_service" &>/dev/null 2>&1 && systemctl cat "$docker_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${docker_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$sysbox_service" &>/dev/null 2>&1 && systemctl cat "$sysbox_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${sysbox_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_root_conflict() {
    local root="${1:-$DOCKYARD_ROOT}"
    if [ -d "${root}/bin" ]; then
        echo "Error: ${root}/bin/ already exists — dockyard is already installed at this root." >&2
        echo "Use: DOCKYARD_ROOT=/other/path ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_private_cidr() {
    local cidr="$1"
    local label="$2"
    local ip="${cidr%/*}"
    local o1 o2
    IFS='.' read -r o1 o2 _ <<< "$ip"

    # 10.0.0.0/8
    if [ "$o1" -eq 10 ]; then return 0; fi
    # 172.16.0.0/12
    if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi
    # 192.168.0.0/16
    if [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then return 0; fi

    echo "Error: ${label} ${cidr} is not in an RFC 1918 private range." >&2
    echo "  Valid ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16" >&2
    return 1
}

check_subnet_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"

    local fixed_net="${fixed_cidr%/*}"
    if ip route | grep -qF "${fixed_net}/"; then
        echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} conflicts with an existing route:" >&2
        echo "  $(ip route | grep -F "${fixed_net}/")" >&2
        return 1
    fi

    local pool_net="${pool_base%/*}"
    local pool_two_octets="${pool_net%.*.*}"
    if ip route | grep -qE "^${pool_two_octets}\."; then
        echo "Error: DOCKYARD_POOL_BASE ${pool_base} overlaps with existing routes:" >&2
        echo "  $(ip route | grep -E "^${pool_two_octets}\.")" >&2
        return 1
    fi
    return 0
}

# Cross-check proposed CIDRs against sibling dockyard env files in the given
# directory.  Prevents gen-env for instance B from picking a pool range that
# shares a /16 with instance A's bridge CIDR (and vice versa), which would
# cause a conflict when concurrent creates bring A's bridge up before B's
# check_subnet_conflict runs.
check_sibling_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"
    local env_dir="$3"

    [ -d "$env_dir" ] || return 0

    local our_bridge_two our_pool_two
    our_bridge_two="${fixed_cidr%.*.*}"     # e.g. "172.21" from 172.21.116.0/24
    our_pool_two="${pool_base%/*}"
    our_pool_two="${our_pool_two%.*.*}"     # e.g. "172.21" from 172.21.0.0/16

    for sibling in "${env_dir}"/*.env; do
        [ -f "$sibling" ] || continue
        local sib_fixed sib_pool
        sib_fixed=$(grep '^DOCKYARD_FIXED_CIDR=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        sib_pool=$(grep '^DOCKYARD_POOL_BASE=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        [ -n "${sib_fixed}${sib_pool}" ] || continue

        if [ -n "$sib_fixed" ]; then
            local sib_two="${sib_fixed%.*.*}"
            # Our pool must not share a /16 with a sibling's bridge
            if [ "$our_pool_two" = "$sib_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling bridge ${sib_fixed} (from ${sibling})" >&2
                return 1
            fi
        fi
        if [ -n "$sib_pool" ]; then
            local sib_pool_two="${sib_pool%/*}"
            sib_pool_two="${sib_pool_two%.*.*}"
            # Our bridge must not share a /16 with a sibling's pool
            if [ "$our_bridge_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
            # Our pool must not share a /16 with a sibling's pool
            if [ "$our_pool_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
        fi
    done
    return 0
}

# ── Commands ─────────────────────────────────────────────────

cmd_gen_env() {
    local NOCHECK=false
    for arg in "$@"; do
        case "$arg" in
            --nocheck)  NOCHECK=true ;;
            -h|--help)  gen_env_usage ;;
            --*)        echo "Unknown option: $arg" >&2; gen_env_usage ;;
        esac
    done

    # Determine output file
    local out_file="${DOCKYARD_ENV:-./dockyard.env}"
    if [ -f "$out_file" ]; then
        echo "Error: ${out_file} already exists. Remove it first or set DOCKYARD_ENV to a different path." >&2
        exit 1
    fi

    # Apply env var overrides or defaults
    local root="${DOCKYARD_ROOT:-/dockyard}"
    local prefix="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    local pool_size="${DOCKYARD_POOL_SIZE:-24}"

    # Generate random networks if not provided via env
    local bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-}"
    local fixed_cidr="${DOCKYARD_FIXED_CIDR:-}"
    local pool_base="${DOCKYARD_POOL_BASE:-}"

    if [ -z "$bridge_cidr" ] || [ -z "$fixed_cidr" ] || [ -z "$pool_base" ]; then
        local attempts=0
        local max_attempts=10

        while [ $attempts -lt $max_attempts ]; do
            attempts=$((attempts + 1))

            # Random /24 from 172.16.0.0/12 for bridge
            local b2=$(( RANDOM % 16 + 16 ))   # 16-31
            local b3=$(( RANDOM % 256 ))        # 0-255
            bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-172.${b2}.${b3}.1/24}"
            fixed_cidr="${DOCKYARD_FIXED_CIDR:-172.${b2}.${b3}.0/24}"

            # Random /16 from 172.16.0.0/12 for pool (different second octet)
            local p2=$(( RANDOM % 16 + 16 ))    # 16-31
            while [ "$p2" -eq "$b2" ]; do
                p2=$(( RANDOM % 16 + 16 ))
            done
            pool_base="${DOCKYARD_POOL_BASE:-172.${p2}.0.0/16}"

            if [ "$NOCHECK" = true ]; then
                break
            fi

            local env_dir
            env_dir="$(cd "$(dirname "${out_file}")" 2>/dev/null && pwd)" || env_dir=""
            if check_subnet_conflict "$fixed_cidr" "$pool_base" 2>/dev/null && \
               check_sibling_conflict "$fixed_cidr" "$pool_base" "$env_dir" 2>/dev/null; then
                break
            fi

            # Reset for next attempt (only re-randomize what wasn't user-provided)
            [ -n "${DOCKYARD_BRIDGE_CIDR:-}" ] || bridge_cidr=""
            [ -n "${DOCKYARD_FIXED_CIDR:-}" ] || fixed_cidr=""
            [ -n "${DOCKYARD_POOL_BASE:-}" ] || pool_base=""

            if [ $attempts -eq $max_attempts ]; then
                echo "Error: Could not find non-conflicting subnets after ${max_attempts} attempts." >&2
                echo "Provide explicit values via DOCKYARD_BRIDGE_CIDR, DOCKYARD_FIXED_CIDR, DOCKYARD_POOL_BASE." >&2
                exit 1
            fi
        done
    else
        # All three provided explicitly — validate unless --nocheck
        if [ "$NOCHECK" = false ]; then
            check_subnet_conflict "$fixed_cidr" "$pool_base" || exit 1
        fi
    fi

    # Validate all CIDRs are in RFC 1918 private ranges
    check_private_cidr "$bridge_cidr" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$fixed_cidr"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$pool_base"   "DOCKYARD_POOL_BASE"   || exit 1

    # Conflict checks (unless --nocheck)
    if [ "$NOCHECK" = false ]; then
        check_prefix_conflict "$prefix" || exit 1
        check_root_conflict "$root" || exit 1
    fi

    # Write config file
    cat > "$out_file" <<EOF
# Dockyard configuration
# Generated by: dockyard.sh gen-env

DOCKYARD_ROOT=${root}
DOCKYARD_DOCKER_PREFIX=${prefix}
DOCKYARD_BRIDGE_CIDR=${bridge_cidr}
DOCKYARD_FIXED_CIDR=${fixed_cidr}
DOCKYARD_POOL_BASE=${pool_base}
DOCKYARD_POOL_SIZE=${pool_size}
EOF

    echo "Generated ${out_file}:"
    echo ""
    cat "$out_file"
}

cmd_create() {
    local INSTALL_SYSTEMD=true
    local START_DAEMON=true
    for arg in "$@"; do
        case "$arg" in
            --no-systemd) INSTALL_SYSTEMD=false ;;
            --no-start)   START_DAEMON=false ;;
            -h|--help)    create_usage ;;
            --*)          echo "Unknown option: $arg" >&2; create_usage ;;
        esac
    done

    require_root

    # Preflight: check for required system tools
    local missing=()
    for tool in curl iptables rsync; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: missing required tools: ${missing[*]}" >&2
        echo "Install them first, e.g.: apt-get install -y ${missing[*]}" >&2
        exit 1
    fi

    echo "Installing dockyard docker..."
    echo "  DOCKYARD_ROOT:          ${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX: ${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR:   ${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR:    ${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE:     ${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE:     ${DOCKYARD_POOL_SIZE}"
    echo ""
    echo "  bridge:      ${BRIDGE}"
    echo "  service:     ${SERVICE_NAME}.service"
    echo "  root:        ${DOCKYARD_ROOT}"
    echo "  data:        ${DOCKER_DATA}"
    echo "  socket:      ${DOCKER_SOCKET}"
    echo "  user:        ${INSTANCE_USER}"
    echo "  group:       ${INSTANCE_GROUP}"
    echo ""

    # --- Check for existing installation ---
    check_private_cidr "$DOCKYARD_BRIDGE_CIDR" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$DOCKYARD_FIXED_CIDR"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$DOCKYARD_POOL_BASE"   "DOCKYARD_POOL_BASE"   || exit 1
    check_root_conflict "$DOCKYARD_ROOT" || exit 1
    check_prefix_conflict "$DOCKYARD_DOCKER_PREFIX" || exit 1
    check_subnet_conflict "$DOCKYARD_FIXED_CIDR" "$DOCKYARD_POOL_BASE" || exit 1

    # --- 1. Download and extract binaries ---
    local CACHE_DIR="${SCRIPT_DIR}/.tmp"

    # Version compatibility notes — do not upgrade these without reading:
    #
    # DOCKER_VERSION: static binary from download.docker.com/linux/static/stable.
    #   Uses sysbox-runc as default runtime → the bundled runc 1.3.3 is never
    #   called for sandbox containers, so this version does NOT trigger the
    #   sysbox procfs incompatibility (nestybox/sysbox#973).
    #
    # SYSBOX_VERSION: 0.6.7.10-tc is a patched fork (github.com/thieso2/sysbox)
    #   that adds --run-dir to sysbox-mgr, sysbox-fs, and sysbox-runc, allowing
    #   N independent sysbox instances per host (each with its own socket dir).
    #   SetRunDir() calls os.Setenv("SYSBOX_RUN_DIR", dir) and os.Args is scanned
    #   directly in init() — bypasses urfave/cli v1 so --run-dir via runtimeArgs
    #   works correctly for all three sockets including the seccomp tracer.
    #   No wrapper script needed.
    #   Fixed: https://github.com/thieso2/sysbox/issues/5
    #   Distributed as a static tarball (no .deb, no dpkg dependency).
    #   0.6.7.10-tc is the first release with an aarch64 static tarball.
    #   NOTE: 0.7.0.1-tc has a netns regression — do not upgrade until fixed
    #   (see https://github.com/thieso2/sysbox/issues/9)

    # --- Detect CPU architecture ---
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
    echo "  arch:        ${ARCH}"
    echo ""

    local DOCKER_VERSION="29.2.1"
    local DOCKER_ROOTLESS_VERSION="29.2.1"
    local SYSBOX_VERSION="0.7.0.6-tc"
    local SYSBOX_TARBALL="sysbox-static-${ARCH}.tar.gz"
    local COMPOSE_VERSION="2.32.4"

    # SHA256 checksums — must match exactly; cache hits are also verified
    # (protects against cache poisoning and mirror tampering)
    local DOCKER_SHA256 DOCKER_ROOTLESS_SHA256 SYSBOX_SHA256 COMPOSE_SHA256
    case "$ARCH" in
        x86_64)
            DOCKER_SHA256="995b1d0b51e96d551a3b49c552c0170bc6ce9f8b9e0866b8c15bbc67d1cf93a3"
            DOCKER_ROOTLESS_SHA256="8c7b7783d8b391ca3183d9b5c7dea1794f6de69cfaa13c45f61fcd17d2b9c3ef"
            SYSBOX_SHA256="91f44ab16948a14c4df8225d254e730e616b952a74879eb0a874692690fae20b"
            COMPOSE_SHA256="ed1917fb54db184192ea9d0717bcd59e3662ea79db48bff36d3475516c480a6b"
            ;;
        aarch64)
            DOCKER_SHA256="236c5064473295320d4bf732fbbfc5b11b6b2dc446e8bc7ebb9222015fb36857"
            DOCKER_ROOTLESS_SHA256="15895df8b46ff33179d357e61b600b5b51242f9b9587c0f66695689e62f57894"
            SYSBOX_SHA256="9601a03ab1455bf3a3409c7cc09df864df8c717c38e35f0c13ded80665b89d81"
            COMPOSE_SHA256="0c4591cf3b1ed039adcd803dbbeddf757375fc08c11245b0154135f838495a2f"
            ;;
    esac

    local DOCKER_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz"
    local DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
    local SYSBOX_URL="https://github.com/thieso2/sysbox/releases/download/v${SYSBOX_VERSION}/${SYSBOX_TARBALL}"
    local COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "$ETC_DIR" "$BIN_DIR"
    mkdir -p "$DOCKER_DATA" "$DOCKER_CONFIG_DIR"
    mkdir -p "${RUN_DIR}/containerd"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$SYSBOX_RUN_DIR"
    mkdir -p "$SYSBOX_DATA_DIR"

    # Create system user and group for this instance.
    # dockerd runs as root but creates the socket owned by this group (--group flag),
    # so operators simply join the group to get socket access without sudo.
    if ! getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupadd --system "${INSTANCE_GROUP}"
        echo "  Created group ${INSTANCE_GROUP}"
    else
        echo "  Group ${INSTANCE_GROUP} already exists"
    fi
    if ! getent passwd "${INSTANCE_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false \
            --gid "${INSTANCE_GROUP}" "${INSTANCE_USER}"
        echo "  Created user ${INSTANCE_USER}"
    else
        echo "  User ${INSTANCE_USER} already exists"
    fi

    # Allow sysbox-fs FUSE mounts at this instance's sysbox mountpoint.
    # The default fusermount3 AppArmor profile (tightened in Ubuntu 25.10+)
    # only permits FUSE mounts under $HOME, /mnt, /tmp, etc.  Without this
    # override every sysbox container fails with a context-deadline-exceeded
    # RPC error from sysbox-fs.
    # Each instance appends a tagged block; destroy removes it.
    if [ -d /etc/apparmor.d ]; then
        mkdir -p /etc/apparmor.d/local
        local apparmor_file="/etc/apparmor.d/local/fusermount3"
        local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
        local apparmor_end="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end"
        {
            flock -x 9
            if ! grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
                {
                    echo "$apparmor_begin"
                    # Ubuntu 25.10+ comments out dac_override in the base fusermount3
                    # profile (LP: #2122161). sysbox-fs needs it for FUSE mounts.
                    echo "capability dac_override,"
                    echo "mount fstype=fuse options=(nosuid,nodev) options in (ro,rw) -> ${SYSBOX_DATA_DIR}/**/,"
                    echo "umount ${SYSBOX_DATA_DIR}/**/,"
                    echo "$apparmor_end"
                } >> "$apparmor_file"
            fi
        } 9>"${apparmor_file}.lock"
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3
            echo "  AppArmor fusermount3 profile updated for ${SYSBOX_DATA_DIR}"
        fi
    fi

    verify_checksum() {
        local file="$1" expected="$2" name="$3"
        local actual
        actual=$(sha256sum "$file" | awk '{print $1}')
        if [ "$actual" != "$expected" ]; then
            echo "Error: SHA256 mismatch for $name" >&2
            echo "  expected: $expected" >&2
            echo "  got:      $actual" >&2
            rm -f "$file"
            exit 1
        fi
    }

    download() {
        local url="$1"
        local expected_sha256="$2"
        local dest="${CACHE_DIR}/$(basename "$url")"
        if [ -f "$dest" ]; then
            echo "  cached: $(basename "$dest")"
        else
            echo "  downloading: $(basename "$url")"
            curl -fsSL -o "${dest}.tmp.$$" "$url" && mv "${dest}.tmp.$$" "$dest"
        fi
        verify_checksum "$dest" "$expected_sha256" "$(basename "$url")"
    }

    echo "Downloading artifacts..."
    download "$DOCKER_URL"          "$DOCKER_SHA256"
    download "$DOCKER_ROOTLESS_URL" "$DOCKER_ROOTLESS_SHA256"
    download "$SYSBOX_URL"          "$SYSBOX_SHA256"
    download "$COMPOSE_URL"         "$COMPOSE_SHA256"

    # Use per-PID staging dirs for extraction so concurrent creates don't race
    # on a shared extraction directory (all instances share the same CACHE_DIR).
    local STAGING="${CACHE_DIR}/staging-$$"
    mkdir -p "$STAGING"
    trap 'rm -rf "$STAGING"' RETURN INT TERM

    echo "Extracting Docker binaries..."
    tar -xzf "${CACHE_DIR}/docker-${DOCKER_VERSION}.tgz" -C "$STAGING"
    cp -f "${STAGING}/docker/"* "$BIN_DIR/"

    echo "Extracting Docker rootless extras..."
    tar -xzf "${CACHE_DIR}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz" -C "$STAGING"
    cp -f "${STAGING}/docker-rootless-extras/"* "$BIN_DIR/"

    echo "Extracting sysbox static binaries..."
    local SYSBOX_EXTRACT="${STAGING}/sysbox-static-${SYSBOX_VERSION}"
    mkdir -p "$SYSBOX_EXTRACT"
    tar -xzf "${CACHE_DIR}/${SYSBOX_TARBALL}" -C "$SYSBOX_EXTRACT"
    # All three sysbox binaries go directly to BIN_DIR.
    # sysbox-runc 0.6.7.9-tc parses --run-dir directly from os.Args in init(),
    # bypassing urfave/cli v1 entirely. runtimeArgs in daemon.json now works.
    # See: https://github.com/thieso2/sysbox/issues/5
    for bin in sysbox-runc sysbox-mgr sysbox-fs; do
        local src
        src=$(find "$SYSBOX_EXTRACT" -name "$bin" -type f | head -1)
        if [ -z "$src" ]; then
            echo "Error: $bin not found in ${SYSBOX_TARBALL}" >&2
            exit 1
        fi
        cp -f "$src" "$BIN_DIR/$bin"
        chmod +x "$BIN_DIR/$bin"
    done

    # Install Docker Compose v2 plugin
    echo "Installing Docker Compose plugin..."
    mkdir -p "${DOCKER_CONFIG_DIR}/cli-plugins"
    cp -f "${CACHE_DIR}/docker-compose-linux-${ARCH}" "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose"
    chmod +x "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose"

    chmod +x "$BIN_DIR"/*

    # Rename docker CLI binary, replace with DOCKER_HOST wrapper
    mv -f "${BIN_DIR}/docker" "${BIN_DIR}/docker-cli"
    cat > "${BIN_DIR}/docker" <<DOCKEREOF
#!/bin/bash
export DOCKER_HOST="unix://${DOCKER_SOCKET}"
export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"
exec "\$(dirname "\$0")/docker-cli" "\$@"
DOCKEREOF
    chmod +x "${BIN_DIR}/docker"

    echo "Installed binaries to ${BIN_DIR}/"

    # Detect storage driver and backing filesystem.
    # sysbox requires overlay2 — ZFS native driver causes "unknown fs" errors.
    # overlay2 works on ZFS 2.2+ with overlayfs kernel support.
    local STORAGE_DRIVER BACKING_FS
    STORAGE_DRIVER=$(detect_storage_driver "$DOCKER_DATA")
    BACKING_FS=$(detect_backing_fs "$DOCKER_DATA")
    echo "  storage:     ${STORAGE_DRIVER} (on ${BACKING_FS})"
    echo ""

    # Detect host upstream DNS so containers don't fall back to Docker's
    # hardcoded 8.8.8.8 when /etc/resolv.conf points at systemd-resolved.
    # See https://github.com/thieso2/dockyard/issues/19.
    local DNS_JSON="" dns_list dns_ip dns_joined=""
    dns_list=$(detect_upstream_dns)
    if [ -n "$dns_list" ]; then
        for dns_ip in $dns_list; do
            if [ -z "$dns_joined" ]; then
                dns_joined="\"${dns_ip}\""
            else
                dns_joined="${dns_joined},\"${dns_ip}\""
            fi
        done
        DNS_JSON="  \"dns\": [${dns_joined}],"$'\n'
        echo "  dns:         ${dns_list}"
    else
        echo "  dns:         (none detected — Docker will use built-in fallback)"
    fi

    # Write daemon.json (embedded — no external file dependency)
    # sysbox-runc 0.6.7.9-tc parses --run-dir from os.Args in init(), so
    # runtimeArgs works correctly. No wrapper script needed.
    cat > "${ETC_DIR}/daemon.json" <<DAEMONJSONEOF
{
  "default-runtime": "sysbox-runc",
  "runtimes": {
    "sysbox-runc": {
      "path": "${BIN_DIR}/sysbox-runc",
      "runtimeArgs": ["--run-dir", "${SYSBOX_RUN_DIR}"]
    }
  },
  "storage-driver": "${STORAGE_DRIVER}",
  "userland-proxy-path": "${BIN_DIR}/docker-proxy",
${DNS_JSON}  "features": {
    "buildkit": true
  }
}
DAEMONJSONEOF
    echo "Installed config to ${ETC_DIR}/daemon.json"

    # Copy config file and dockyard.sh into instance.
    # Installing as dockyard.sh means the script's own ../etc/dockyard.env
    # auto-discovery works: ${BIN_DIR}/dockyard.sh finds ${ETC_DIR}/dockyard.env
    # without needing DOCKYARD_ENV to be set.
    cp "$LOADED_ENV_FILE" "${ETC_DIR}/dockyard.env"
    cp "${SCRIPT_DIR}/dockyard.sh" "${BIN_DIR}/dockyard.sh"
    chmod +x "${BIN_DIR}/dockyard.sh"
    ln -sf dockyard.sh "${BIN_DIR}/dockyardctl"
    echo "Installed env to ${ETC_DIR}/dockyard.env"
    echo "Installed dockyard.sh to ${BIN_DIR}/dockyard.sh"

    # Set ownership of the instance root so every file is attributed to the
    # instance user/group. dockerd still runs as root, so it can write freely;
    # the ownership is for identification and directory-level access control.
    chown -R "${INSTANCE_USER}:${INSTANCE_GROUP}" "${DOCKYARD_ROOT}"
    echo "Set ownership of ${DOCKYARD_ROOT}/ to ${INSTANCE_USER}:${INSTANCE_GROUP}"

    # --- 2. Install systemd service ---
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo ""
        cmd_enable
    fi

    # --- 3. Start daemon ---
    if [ "$START_DAEMON" = true ]; then
        echo ""
        if [ "$INSTALL_SYSTEMD" = true ]; then
            echo "Starting via systemd..."
            systemctl start "${SERVICE_NAME}.service"
            echo "  ${SERVICE_NAME}.service started"
        else
            echo "Starting directly..."
            cmd_start
        fi
    fi

    echo ""
    echo "=== Installation complete ==="
    echo ""
    echo "To use:"
    echo "  ${BIN_DIR}/docker run -ti alpine ash"
    echo ""
    echo "Manage this instance:"
    echo "  ${BIN_DIR}/dockyard.sh status"
    echo "  sudo ${BIN_DIR}/dockyard.sh verify"
    echo "  sudo ${BIN_DIR}/dockyard.sh destroy"
}

cmd_enable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "Error: ${SERVICE_FILE} already exists." >&2
        exit 1
    fi

    echo "Installing ${SERVICE_NAME}.service (with per-instance sysbox)..."

    # Write the stack script (bakes all paths in at install time; no env file at runtime)
    cat > "${BIN_DIR}/dockyard-stack" <<STACKEOF
#!/bin/bash
set -euo pipefail

MGR_PID=""
FS_PID=""
CTR_PID=""
DOCKERD_PID=""

wait_for_socket() {
    local sock="\$1" pid="\$2" name="\$3" i=0
    while [ ! -S "\$sock" ]; do
        sleep 1
        i=\$((i+1))
        if ! kill -0 "\$pid" 2>/dev/null; then
            echo "dockyard-stack: \$name exited unexpectedly" >&2
            return 1
        fi
        if [ "\$i" -ge 60 ]; then
            echo "dockyard-stack: \$name did not start within 60s" >&2
            return 1
        fi
    done
}

cleanup() {
    local code=\${1:-0}
    for pid in "\$DOCKERD_PID" "\$CTR_PID" "\$FS_PID" "\$MGR_PID"; do
        [ -z "\$pid" ] && continue
        kill "\$pid" 2>/dev/null || true
        wait "\$pid" 2>/dev/null || true
    done
    exit "\$code"
}

trap 'cleanup 0' TERM INT

# --- Start sysbox-mgr ---
${BIN_DIR}/sysbox-mgr --run-dir ${SYSBOX_RUN_DIR} --data-root ${SYSBOX_DATA_DIR} \
    >>${LOG_DIR}/sysbox-mgr.log 2>&1 &
MGR_PID=\$!
echo "\$MGR_PID" > ${SYSBOX_RUN_DIR}/sysbox-mgr.pid
wait_for_socket ${SYSBOX_RUN_DIR}/sysmgr.sock "\$MGR_PID" sysbox-mgr || cleanup 1

# --- Start sysbox-fs ---
${BIN_DIR}/sysbox-fs --run-dir ${SYSBOX_RUN_DIR} --mountpoint ${SYSBOX_DATA_DIR} \
    >>${LOG_DIR}/sysbox-fs.log 2>&1 &
FS_PID=\$!
echo "\$FS_PID" > ${SYSBOX_RUN_DIR}/sysbox-fs.pid
wait_for_socket ${SYSBOX_RUN_DIR}/sysfs.sock "\$FS_PID" sysbox-fs || cleanup 1

# --- Start containerd ---
${BIN_DIR}/containerd \
    --root ${DOCKER_DATA}/containerd \
    --state ${RUN_DIR}/containerd \
    --address ${CONTAINERD_SOCKET} \
    >>${LOG_DIR}/containerd.log 2>&1 &
CTR_PID=\$!
echo "\$CTR_PID" > ${RUN_DIR}/containerd.pid
wait_for_socket ${CONTAINERD_SOCKET} "\$CTR_PID" containerd || cleanup 1

# --- Start dockerd ---
${BIN_DIR}/dockerd \
    --config-file ${ETC_DIR}/daemon.json \
    --containerd ${CONTAINERD_SOCKET} \
    --data-root ${DOCKER_DATA} \
    --exec-root ${RUN_DIR} \
    --pidfile ${RUN_DIR}/dockerd.pid \
    --bridge ${BRIDGE} \
    --fixed-cidr ${DOCKYARD_FIXED_CIDR} \
    --default-address-pool base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE} \
    --host unix://${DOCKER_SOCKET} \
    --iptables=false \
    --group ${INSTANCE_GROUP} \
    >>${LOG_DIR}/dockerd.log 2>&1 &
DOCKERD_PID=\$!
wait_for_socket ${DOCKER_SOCKET} "\$DOCKERD_PID" dockerd || cleanup 1

# Signal systemd that all daemon sockets are up.
# || true: sd_notify returns non-zero when not running under systemd; don't abort.
systemd-notify --ready 2>/dev/null || true

# Monitor: if any daemon dies, trigger a restart
while true; do
    sleep 2 &
    wait \$! 2>/dev/null || true
    for check in "sysbox-mgr:\$MGR_PID" "sysbox-fs:\$FS_PID" "containerd:\$CTR_PID" "dockerd:\$DOCKERD_PID"; do
        _name="\${check%%:*}"
        _pid="\${check##*:}"
        if [ -n "\$_pid" ] && ! kill -0 "\$_pid" 2>/dev/null; then
            echo "dockyard-stack: \$_name (pid \$_pid) died unexpectedly" >&2
            cleanup 1
        fi
    done
done
STACKEOF
    chmod 755 "${BIN_DIR}/dockyard-stack"
    echo "  installed ${BIN_DIR}/dockyard-stack"

    local ISO_CHAIN="DOCKYARD-ISO-${DOCKYARD_DOCKER_PREFIX%_}"

    cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=Dockyard Docker (${SERVICE_NAME})
After=network-online.target nss-lookup.target firewalld.service time-set.target
Before=docker.service
Wants=network-online.target
RequiresMountsFor=${DOCKYARD_ROOT}
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=notify
NotifyAccess=all
Environment=PATH=${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Create runtime and sysbox directories
ExecStartPre=/bin/mkdir -p ${LOG_DIR} ${RUN_DIR}/containerd ${SYSBOX_RUN_DIR} ${DOCKER_DATA}/containerd ${SYSBOX_DATA_DIR}

# Clean stale sockets (including sysbox — stale socket file fools the wait loop)
ExecStartPre=-/bin/rm -f ${CONTAINERD_SOCKET} ${DOCKER_SOCKET}
ExecStartPre=-/bin/rm -f ${SYSBOX_RUN_DIR}/sysmgr.sock ${SYSBOX_RUN_DIR}/sysfs.sock ${SYSBOX_RUN_DIR}/sysfs-seccomp.sock

# Enable IP forwarding and bridge netfilter (needed for isolation.d iptables on bridge traffic)
ExecStartPre=/bin/bash -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null; modprobe br_netfilter 2>/dev/null; sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true'

# Create bridge
ExecStartPre=/bin/bash -c 'if ! ip link show ${BRIDGE} &>/dev/null; then ip link add ${BRIDGE} type bridge && ip addr add ${DOCKYARD_BRIDGE_CIDR} dev ${BRIDGE} && ip link set ${BRIDGE} up; fi'

# Add iptables rules for container networking (bridge) — idempotent: -C check before -I
ExecStartPre=/bin/bash -c 'iptables -C FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT; iptables -C FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT; iptables -C FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -C POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE'

# Add iptables rules for user-defined networks (from default-address-pool) — idempotent
ExecStartPre=/bin/bash -c 'iptables -C FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT; iptables -C FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT; iptables -t nat -C POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE'

# Stack script starts sysbox-mgr, sysbox-fs, containerd, dockerd; sends READY once sockets
# are up; then monitors. ExecStartPost gates systemctl-start on full API readiness so callers
# of "systemctl start" don't proceed until docker accepts connections.
ExecStart=${BIN_DIR}/dockyard-stack

# Wait until dockerd accepts API connections before systemctl start returns.
ExecStartPost=/bin/bash -c 'i=0; while ! ${BIN_DIR}/docker-cli -H unix://${DOCKER_SOCKET} info >/dev/null 2>&1; do i=\$((i+1)); [ \$i -ge 360 ] && exit 1; sleep 0.5; done'

# Apply isolation rules from ${ETC_DIR}/isolation.d/ if any .rules files exist.
# Each .rules file lists IPs to ACCEPT; all other intra-bridge traffic is DROPped.
# Chain ${ISO_CHAIN} is per-instance; built once, then jump rules added per user-defined bridge.
# Containers on the same bridge subnet are auto-whitelisted (intra-bridge communication).
ExecStartPost=-/bin/bash -c 'dir=${ETC_DIR}/isolation.d; ls "\$dir"/*.rules >/dev/null 2>&1 || exit 0; iptables -L ${ISO_CHAIN} >/dev/null 2>&1 || iptables -N ${ISO_CHAIN}; iptables -F ${ISO_CHAIN}; iptables -A ${ISO_CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; for f in "\$dir"/*.rules; do [ -f "\$f" ] || continue; sed "s/#.*//;s/ //g;/^$/d" "\$f" | while IFS= read -r line; do iptables -A ${ISO_CHAIN} -s "\$line" -j ACCEPT; iptables -A ${ISO_CHAIN} -d "\$line" -j ACCEPT; done; done; for net_id in \$(${BIN_DIR}/docker-cli -H unix://${DOCKER_SOCKET} network ls --filter driver=bridge --format "{{.ID}}" 2>/dev/null); do br=br-\$(echo \$net_id | cut -c1-12); ip link show "\$br" &>/dev/null || continue; br_cidr=\$(ip -4 -o addr show "\$br" 2>/dev/null | awk "{print \\\$4}"); [ -n "\$br_cidr" ] && iptables -A ${ISO_CHAIN} -s "\$br_cidr" -j ACCEPT && iptables -A ${ISO_CHAIN} -d "\$br_cidr" -j ACCEPT; done; iptables -A ${ISO_CHAIN} -j DROP; for net_id in \$(${BIN_DIR}/docker-cli -H unix://${DOCKER_SOCKET} network ls --filter driver=bridge --format "{{.ID}}" 2>/dev/null); do br=br-\$(echo \$net_id | cut -c1-12); ip link show "\$br" &>/dev/null || continue; iptables -C FORWARD -i "\$br" -o "\$br" -j ${ISO_CHAIN} 2>/dev/null || iptables -I FORWARD -i "\$br" -o "\$br" -j ${ISO_CHAIN}; done'

# Clean up docker/containerd sockets
ExecStopPost=-/bin/rm -f ${DOCKER_SOCKET} ${CONTAINERD_SOCKET}

# Remove iptables rules (bridge)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null'

# Remove iptables rules (user-defined networks)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE 2>/dev/null'

# Remove per-instance isolation chain and its jump rules
ExecStopPost=-/bin/bash -c 'for br in \$(ip -o link show type bridge 2>/dev/null | grep -oP "br-[0-9a-f]+"); do iptables -D FORWARD -i "\$br" -o "\$br" -j ${ISO_CHAIN} 2>/dev/null; done; iptables -F ${ISO_CHAIN} 2>/dev/null; iptables -X ${ISO_CHAIN} 2>/dev/null'

# Remove bridge
ExecStopPost=-/bin/bash -c 'if ip link show ${BRIDGE} &>/dev/null; then ip link set ${BRIDGE} down 2>/dev/null; ip link delete ${BRIDGE} 2>/dev/null; fi'

# Clean up sysbox run dir
ExecStopPost=-/bin/rm -rf ${SYSBOX_RUN_DIR}

TimeoutStartSec=180
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
SERVICEEOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    echo "  enabled ${SERVICE_NAME}.service (will start on boot)"
    echo ""
    echo "  sudo systemctl start ${SERVICE_NAME}    # start"
    echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
}

cmd_disable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "Stopping ${SERVICE_NAME}..."
            systemctl stop "${SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SERVICE_FILE"
        echo "Removed ${SERVICE_FILE}"
    else
        echo "Warning: ${SERVICE_FILE} does not exist." >&2
    fi

    systemctl daemon-reload
}

cmd_start() {
    require_root

    export PATH="${BIN_DIR}:${PATH}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "${RUN_DIR}/containerd" "$DOCKER_DATA/containerd"

    # Clean up stale sockets/pids from previous runs
    rm -f "$CONTAINERD_SOCKET" "$DOCKER_SOCKET"
    rm -f "${SYSBOX_RUN_DIR}/sysmgr.sock" "${SYSBOX_RUN_DIR}/sysfs.sock" "${SYSBOX_RUN_DIR}/sysfs-seccomp.sock"
    for pidfile in "${RUN_DIR}/containerd.pid" "${RUN_DIR}/dockerd.pid"; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            kill "$pid" 2>/dev/null && sleep 1 || true
            rm -f "$pidfile"
        fi
    done

    # Cleanup helper: kill previously started daemons on failure
    STARTED_PIDS=()
    cleanup() {
        echo "Startup failed — cleaning up..."
        for pid in "${STARTED_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        exit 1
    }

    # --- 1. Start per-instance sysbox daemons ---
    mkdir -p "$SYSBOX_RUN_DIR" "$SYSBOX_DATA_DIR"

    echo "Starting sysbox-mgr..."
    "${BIN_DIR}/sysbox-mgr" --run-dir "${SYSBOX_RUN_DIR}" --data-root "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-mgr.log" &
    SYSBOX_MGR_PID=$!
    echo "$SYSBOX_MGR_PID" > "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    STARTED_PIDS+=("$SYSBOX_MGR_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysmgr.sock" "sysbox-mgr" 60 || cleanup
    kill -0 "$SYSBOX_MGR_PID" 2>/dev/null || { echo "sysbox-mgr exited unexpectedly" >&2; cleanup; }
    echo "  sysbox-mgr ready (pid ${SYSBOX_MGR_PID})"

    echo "Starting sysbox-fs..."
    "${BIN_DIR}/sysbox-fs" --run-dir "${SYSBOX_RUN_DIR}" --mountpoint "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-fs.log" &
    SYSBOX_FS_PID=$!
    echo "$SYSBOX_FS_PID" > "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
    STARTED_PIDS+=("$SYSBOX_FS_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysfs.sock" "sysbox-fs" 60 || cleanup
    kill -0 "$SYSBOX_FS_PID" 2>/dev/null || { echo "sysbox-fs exited unexpectedly" >&2; cleanup; }
    echo "  sysbox-fs ready (pid ${SYSBOX_FS_PID})"

    # --- 2. Create bridge ---
    if ! ip link show "$BRIDGE" &>/dev/null; then
        echo "Creating bridge ${BRIDGE}..."
        ip link add "$BRIDGE" type bridge
        ip addr add "$DOCKYARD_BRIDGE_CIDR" dev "$BRIDGE"
        ip link set "$BRIDGE" up
    else
        echo "Bridge ${BRIDGE} already exists"
    fi

    # Enable IP forwarding and bridge netfilter (needed for isolation.d iptables on bridge traffic)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    modprobe br_netfilter 2>/dev/null || true
    sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true

    # Bridge rules (idempotent)
    iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE

    # Pool rules
    iptables -C FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -C FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE

    # --- 3. Start containerd ---
    echo "Starting containerd..."
    "${BIN_DIR}/containerd" \
        --root "$DOCKER_DATA/containerd" \
        --state "${RUN_DIR}/containerd" \
        --address "$CONTAINERD_SOCKET" \
        &>"${LOG_DIR}/containerd.log" &
    CONTAINERD_PID=$!
    echo "$CONTAINERD_PID" > "${RUN_DIR}/containerd.pid"
    STARTED_PIDS+=("$CONTAINERD_PID")

    wait_for_file "$CONTAINERD_SOCKET" "containerd" || cleanup
    echo "  containerd ready (pid ${CONTAINERD_PID})"

    # --- 4. Start dockerd ---
    echo "Starting dockerd..."
    "${BIN_DIR}/dockerd" \
        --config-file "${ETC_DIR}/daemon.json" \
        --containerd "$CONTAINERD_SOCKET" \
        --data-root "$DOCKER_DATA" \
        --exec-root "$RUN_DIR" \
        --pidfile "${RUN_DIR}/dockerd.pid" \
        --bridge "$BRIDGE" \
        --fixed-cidr "$DOCKYARD_FIXED_CIDR" \
        --default-address-pool "base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE}" \
        --host "unix://${DOCKER_SOCKET}" \
        --iptables=false \
        --group "${INSTANCE_GROUP}" \
        &>"${LOG_DIR}/dockerd.log" &
    DOCKERD_PID=$!
    STARTED_PIDS+=("$DOCKERD_PID")

    wait_for_file "$DOCKER_SOCKET" "dockerd" 30 || cleanup
    echo "  dockerd ready (pid ${DOCKERD_PID})"

    # Apply isolation rules from ${ETC_DIR}/isolation.d/ if any .rules files exist.
    # Each .rules file lists IPs to ACCEPT; all other intra-bridge traffic is DROPped.
    # Containers on the same bridge subnet are always allowed to communicate —
    # isolation controls which external/infrastructure IPs are reachable, not
    # intra-bridge traffic between co-located containers.
    local isolation_dir="${ETC_DIR}/isolation.d"
    local iso_chain="DOCKYARD-ISO-${DOCKYARD_DOCKER_PREFIX%_}"
    if ls "${isolation_dir}"/*.rules >/dev/null 2>&1; then
        # Build the chain once (not per-bridge)
        iptables -L "$iso_chain" >/dev/null 2>&1 || iptables -N "$iso_chain"
        iptables -F "$iso_chain"
        iptables -A "$iso_chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        for f in "${isolation_dir}"/*.rules; do
            [ -f "$f" ] || continue
            while IFS= read -r line; do
                line="${line%%#*}"          # strip comments
                line="${line// /}"          # strip spaces
                [ -n "$line" ] || continue
                iptables -A "$iso_chain" -s "$line" -j ACCEPT
                iptables -A "$iso_chain" -d "$line" -j ACCEPT
            done < "$f"
        done

        # Allow intra-bridge traffic: containers on the same bridge should
        # always be able to communicate. Auto-whitelist each bridge's subnet.
        for net_id in $("${BIN_DIR}/docker-cli" -H "unix://${DOCKER_SOCKET}" network ls \
                --filter driver=bridge --format '{{.ID}}' 2>/dev/null); do
            local br="br-${net_id:0:12}"
            ip link show "$br" &>/dev/null || continue
            local br_cidr
            br_cidr=$(ip -4 -o addr show "$br" 2>/dev/null | awk '{print $4}')
            if [ -n "$br_cidr" ]; then
                iptables -A "$iso_chain" -s "$br_cidr" -j ACCEPT
                iptables -A "$iso_chain" -d "$br_cidr" -j ACCEPT
                echo "  bridge subnet ${br_cidr} whitelisted on ${br}"
            fi
        done

        iptables -A "$iso_chain" -j DROP

        # Add per-bridge jump rules for this instance's user-defined networks
        for net_id in $("${BIN_DIR}/docker-cli" -H "unix://${DOCKER_SOCKET}" network ls \
                --filter driver=bridge --format '{{.ID}}' 2>/dev/null); do
            local br="br-${net_id:0:12}"
            ip link show "$br" &>/dev/null || continue
            iptables -C FORWARD -i "$br" -o "$br" -j "$iso_chain" 2>/dev/null ||
                iptables -I FORWARD -i "$br" -o "$br" -j "$iso_chain"
            echo "  isolation rules applied on ${br}"
        done
    fi

    echo "=== All daemons started ==="
    echo "Run: DOCKER_HOST=unix://${DOCKER_SOCKET} docker ps"
}

cmd_stop() {
    require_root

    # Reverse startup order: dockerd -> containerd -> sysbox
    stop_daemon dockerd "${RUN_DIR}/dockerd.pid" 20
    stop_daemon containerd "${RUN_DIR}/containerd.pid" 10
    stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
    stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
    rm -rf "$SYSBOX_RUN_DIR"

    # Clean up sockets
    rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"

    # Remove iptables rules (bridge)
    iptables -D FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null || true
    # Remove iptables rules (pool)
    iptables -D FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null || true

    # Remove per-instance isolation chain and its jump rules
    local iso_chain="DOCKYARD-ISO-${DOCKYARD_DOCKER_PREFIX%_}"
    for br in $(ip -o link show type bridge 2>/dev/null | grep -oP 'br-[0-9a-f]+'); do
        iptables -D FORWARD -i "$br" -o "$br" -j "$iso_chain" 2>/dev/null || true
    done
    iptables -F "$iso_chain" 2>/dev/null || true
    iptables -X "$iso_chain" 2>/dev/null || true

    # Remove bridge
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link set "$BRIDGE" down
        ip link delete "$BRIDGE"
        echo "Bridge ${BRIDGE} removed"
    fi

    # Remove leftover user-defined network bridges from the pool range
    cleanup_pool_bridges

    echo "=== All daemons stopped ==="
}

cmd_status() {
    echo "=== Dockyard Docker Status ==="
    echo ""

    echo "Variables:"
    echo "  DOCKYARD_ROOT=${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}"
    echo ""

    echo "Derived:"
    echo "  RUN_DIR=${RUN_DIR}"
    echo "  BRIDGE=${BRIDGE}"
    echo "  SERVICE_NAME=${SERVICE_NAME}"
    echo "  DOCKER_SOCKET=${DOCKER_SOCKET}"
    echo "  CONTAINERD_SOCKET=${CONTAINERD_SOCKET}"
    echo ""

    # --- systemd services ---
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "systemd (docker): $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown") ($(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown"))"
    else
        echo "systemd (docker): not installed"
    fi

    # --- pid checks ---
    check_pid() {
        local name="$1"
        local pidfile="$2"
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            if [ -d "/proc/${pid}" ]; then
                echo "${name}: running (pid ${pid})"
            else
                echo "${name}: dead (stale pid ${pid})"
            fi
        else
            echo "${name}: not running"
        fi
    }

    check_pid "sysbox-mgr" "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    check_pid "sysbox-fs " "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
    check_pid "containerd" "${RUN_DIR}/containerd.pid"
    check_pid "dockerd   " "${RUN_DIR}/dockerd.pid"

    # --- bridge ---
    if ip link show "$BRIDGE" &>/dev/null; then
        local local_ip
        local_ip=$(ip -4 addr show "$BRIDGE" 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "no ip")
        echo "bridge:     ${BRIDGE} (${local_ip})"
    else
        echo "bridge:     ${BRIDGE} not found"
    fi

    # --- sockets ---
    if [ -e "$DOCKER_SOCKET" ]; then
        echo "socket:     ${DOCKER_SOCKET}"
    else
        echo "socket:     ${DOCKER_SOCKET} not found"
    fi

    if [ -e "$CONTAINERD_SOCKET" ]; then
        echo "containerd: ${CONTAINERD_SOCKET}"
    else
        echo "containerd: ${CONTAINERD_SOCKET} not found"
    fi

    # --- connectivity test ---
    echo ""
    echo "Connectivity:"
    if [ -e "$DOCKER_SOCKET" ]; then
        echo "  DOCKER_HOST=unix://${DOCKER_SOCKET} docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de'"
        DOCKER_HOST="unix://${DOCKER_SOCKET}" docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de' 2>&1 | sed 's/^/  /'
    else
        echo "  skipped (docker socket not found)"
    fi

    # --- paths ---
    echo ""
    echo "Paths:"
    echo "  root:     ${DOCKYARD_ROOT}"
    echo "  data:     ${DOCKER_DATA}"
    echo "  logs:     ${LOG_DIR}"
}

cmd_destroy() {
    local YES=false
    local KEEP_DATA=false
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)       YES=true ;;
            --keep-data|-k) KEEP_DATA=true ;;
            -h|--help)      usage ;;
        esac
    done

    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [[ "$KEEP_DATA" == true ]]; then
        echo "This will remove the dockyard instance (binaries and config only — data preserved):"
        echo "  ${SERVICE_FILE}"
        echo "  ${DOCKYARD_ROOT}/  (except ${DOCKER_DATA}/)"
    else
        echo "This will remove all installed dockyard docker files:"
        echo "  ${SERVICE_FILE}    (docker systemd service)"
        echo "  ${DOCKYARD_ROOT}/  (all instance data: binaries, config, data, logs, sockets)"
        local data_size
        data_size=$(du -sh "${DOCKER_DATA}" 2>/dev/null | cut -f1 || echo "unknown")
        echo ""
        echo "Warning: this will permanently delete container data:"
        echo "  ${DOCKER_DATA}/  (~${data_size})"
        echo "  Use --keep-data (-k) to preserve container data."
    fi
    echo ""
    if [[ "$YES" != true ]]; then
        read -p "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # --- 1. Stop and remove systemd service (or stop daemons directly) ---
    if [ -f "$SERVICE_FILE" ]; then
        cmd_disable
    else
        # No systemd service — stop daemons directly
        for pidfile in "${RUN_DIR}/dockerd.pid" "${RUN_DIR}/containerd.pid"; do
            if [ -f "$pidfile" ]; then
                local pid
                pid=$(cat "$pidfile")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Stopping pid ${pid}..."
                    kill "$pid" 2>/dev/null || true
                fi
                rm -f "$pidfile"
            fi
        done
        stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
        stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
        rm -rf "$SYSBOX_RUN_DIR"
        rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        sleep 2
    fi

    # --- 1.5. Remove leftover user-defined network bridges from the pool ---
    cleanup_pool_bridges

    # --- 2. Remove AppArmor fusermount3 entry for this instance ---
    local apparmor_file="/etc/apparmor.d/local/fusermount3"
    local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
    if grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
        {
            flock -x 9
            awk -v start="$apparmor_begin" \
                -v stop="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end" \
                '$0 == start { skip=1 } skip { if ($0 == stop) { skip=0 }; next } { print }' \
                "$apparmor_file" > "${apparmor_file}.tmp" \
                && mv "${apparmor_file}.tmp" "$apparmor_file"
        } 9>"${apparmor_file}.lock"
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3 2>/dev/null || true
        fi
        echo "Removed AppArmor fusermount3 entry for ${DOCKYARD_DOCKER_PREFIX}"
    fi

    # --- 3. Remove instance root (selective or full) ---
    if [ -d "$DOCKYARD_ROOT" ]; then
        if [[ "$KEEP_DATA" == true ]]; then
            rm -rf "${DOCKYARD_ROOT}/bin"
            rm -rf "${DOCKYARD_ROOT}/etc"
            rm -rf "${DOCKYARD_ROOT}/log"
            rm -rf "${DOCKYARD_ROOT}/run"
            rm -rf "${DOCKYARD_ROOT}/lib/sysbox"
            rm -rf "${DOCKYARD_ROOT}/lib/docker-config"
            echo "Removed instance files from ${DOCKYARD_ROOT}/"
            echo "Data preserved at ${DOCKER_DATA}"
        else
            # When the data-root sits on a ZFS dataset, Docker (with overlay2)
            # may have created overlay dirs that need normal removal, and
            # rm -rf on a ZFS mountpoint removes contents but can't remove
            # the mountpoint directory itself.
            local on_zfs=false
            if command -v zfs &>/dev/null; then
                local root_dataset
                root_dataset="$(df --output=source "$DOCKYARD_ROOT" 2>/dev/null | tail -1 | tr -d '[:space:]')" || true
                if [ -n "$root_dataset" ] && zfs list "$root_dataset" &>/dev/null; then
                    on_zfs=true
                    # Destroy all child ZFS datasets (Docker layers, etc.)
                    local children
                    children="$(zfs list -r -H -o name "$root_dataset" 2>/dev/null | tail -n +2 | sort -r)" || true
                    if [ -n "$children" ]; then
                        echo "Cleaning up ZFS datasets under ${root_dataset}..."
                        while IFS= read -r ds; do
                            zfs destroy -f "$ds" 2>/dev/null || true
                        done <<< "$children"
                    fi
                fi
            fi
            if [ "$on_zfs" = true ]; then
                # Can't remove ZFS mountpoint itself; remove contents only
                rm -rf "${DOCKYARD_ROOT:?}"/* "${DOCKYARD_ROOT}"/.[!.]* 2>/dev/null || true
                echo "Removed contents of ${DOCKYARD_ROOT}/ (ZFS mountpoint preserved)"
            else
                rm -rf "$DOCKYARD_ROOT"
                echo "Removed ${DOCKYARD_ROOT}/"
            fi
        fi
    fi

    # --- 4. Remove instance user and group ---
    if getent passwd "${INSTANCE_USER}" &>/dev/null; then
        userdel "${INSTANCE_USER}" 2>/dev/null || true
        echo "Removed user ${INSTANCE_USER}"
    fi
    if getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupdel "${INSTANCE_GROUP}" 2>/dev/null || true
        echo "Removed group ${INSTANCE_GROUP}"
    fi

    echo ""
    echo "=== Uninstall complete ==="
}

# ── Verify ───────────────────────────────────────────────────────────────────
# Smoke-tests a running dockyard instance: service, socket, API, containers,
# outbound networking, and Docker-in-Docker (sysbox).
# Exits 0 only when every check passes.

cmd_verify() {
    local _p=0 _f=0
    local _d="${BIN_DIR}/docker"
    local _s="unix://${DOCKER_SOCKET}"
    local out

    _pass() { echo "  PASS: $1"; _p=$((_p + 1)); }
    _fail() { echo "  FAIL: $1 — $2" >&2; _f=$((_f + 1)); }

    echo "=== dockyard verify: ${SERVICE_NAME} ==="
    echo ""

    # 1. systemd service active
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        _pass "systemd service ${SERVICE_NAME} active"
    else
        _fail "systemd service" "${SERVICE_NAME} is $(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo unknown)"
    fi

    # 2. docker socket exists
    if [ -S "${DOCKER_SOCKET}" ]; then
        _pass "docker socket exists"
    else
        _fail "docker socket" "${DOCKER_SOCKET} not found"
    fi

    # 3. docker info (API reachable)
    if DOCKER_HOST="$_s" "$_d" info >/dev/null 2>&1; then
        _pass "docker info (API reachable)"
    else
        out=$(DOCKER_HOST="$_s" "$_d" info 2>&1 | tail -2)
        _fail "docker info" "$out"
    fi

    # 4. basic container run
    out=$(DOCKER_HOST="$_s" "$_d" run --rm alpine echo verify-ok 2>&1)
    if echo "$out" | grep -q "verify-ok"; then
        _pass "container run (alpine echo)"
    else
        _fail "container run" "$out"
    fi

    # 5. outbound networking
    if DOCKER_HOST="$_s" "$_d" run --rm alpine ping -c3 -W2 1.1.1.1 >/dev/null 2>&1; then
        _pass "outbound networking (ping 1.1.1.1)"
    else
        _fail "outbound networking" "ping 1.1.1.1 failed from container"
    fi

    # 6. Docker-in-Docker via sysbox
    local cname="dockyard-verify-$$"
    DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
    # Mask /usr/sbin/zfs inside DinD to prevent the containerd ZFS snapshotter
    # probe from hanging for 10s when the outer filesystem is ZFS.
    if DOCKER_HOST="$_s" "$_d" run -d --name "$cname" -v /dev/null:/usr/sbin/zfs docker:26.1-dind >/dev/null 2>&1; then
        local ready=false i
        for i in $(seq 1 30); do
            if DOCKER_HOST="$_s" "$_d" exec "$cname" docker info >/dev/null 2>&1; then
                ready=true
                break
            fi
            sleep 2
        done
        if $ready; then
            # Preload alpine from host cache to avoid Docker Hub rate limits.
            if [ -f /var/tmp/alpine.tar ]; then
                DOCKER_HOST="$_s" "$_d" exec -i "$cname" docker load < /var/tmp/alpine.tar >/dev/null 2>&1 || true
            fi
            out=$(DOCKER_HOST="$_s" "$_d" exec "$cname" docker run --rm alpine echo dind-ok 2>&1)
            if echo "$out" | grep -q "dind-ok"; then
                _pass "Docker-in-Docker (inner container via sysbox)"
            else
                _fail "DinD inner container" "$out"
            fi
        else
            _fail "DinD" "inner dockerd not ready after 60s"
        fi
        DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
    else
        out=$(DOCKER_HOST="$_s" "$_d" run --name "$cname" -v /dev/null:/usr/sbin/zfs docker:26.1-dind 2>&1 | head -3)
        DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
        _fail "DinD" "could not start docker:26.1-dind — $out"
    fi

    echo ""
    if [ "$_f" -eq 0 ]; then
        echo "All ${_p} checks passed."
    else
        echo "${_p} passed, ${_f} failed."
    fi
    return "$_f"
}

# ── Usage ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./dockyard.sh <command> [options]

Commands:
  gen-env     Generate a conflict-free dockyard.env config file
  create      Download binaries, install config, set up systemd, start daemon
  enable      Install systemd service for this instance
  disable     Remove systemd service for this instance
  start       Start daemons manually (without systemd)
  stop        Stop manually started daemons
  status      Show instance status
  verify      Smoke-test a running instance (service, containers, DinD, networking)
  destroy     Stop and remove everything

All commands except gen-env require a config file:
  1. $DOCKYARD_ENV (if set)
  2. ./dockyard.env (in current directory)
  3. ../etc/dockyard.env (relative to script — for installed copy)
  4. $DOCKYARD_ROOT/etc/dockyard.env

Examples:
  ./dockyard.sh gen-env
  sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  sudo ./dockyard.sh start
  sudo ./dockyard.sh stop
  ./dockyard.sh status
  sudo ./dockyard.sh verify
  sudo ./dockyard.sh destroy
  sudo ./dockyard.sh destroy --keep-data   # preserve container data

  # Multiple instances
  DOCKYARD_DOCKER_PREFIX=test_ DOCKYARD_ROOT=/test ./dockyard.sh gen-env
  DOCKYARD_ENV=./dockyard.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

gen_env_usage() {
    cat <<'EOF'
Usage: ./dockyard.sh gen-env [OPTIONS]

Generate a dockyard.env config file with randomized, conflict-free networks.

Options:
  --nocheck     Skip all conflict checks
  -h, --help    Show this help

Output: ./dockyard.env (or $DOCKYARD_ENV if set). Errors if file exists.

Override any variable via environment:
  DOCKYARD_ROOT           Installation root (default: /dockyard)
  DOCKYARD_DOCKER_PREFIX  Prefix for bridge/service (default: dy_)
  DOCKYARD_BRIDGE_CIDR    Bridge IP/mask (default: random from 172.16.0.0/12)
  DOCKYARD_FIXED_CIDR     Container subnet (default: derived from bridge)
  DOCKYARD_POOL_BASE      Address pool base (default: random from 172.16.0.0/12)
  DOCKYARD_POOL_SIZE      Pool subnet size (default: 24)

Examples:
  ./dockyard.sh gen-env
  DOCKYARD_DOCKER_PREFIX=test_ ./dockyard.sh gen-env
  DOCKYARD_ROOT=/docker2 DOCKYARD_DOCKER_PREFIX=d2_ ./dockyard.sh gen-env
  ./dockyard.sh gen-env --nocheck
EOF
    exit 0
}

create_usage() {
    cat <<'EOF'
Usage: sudo ./dockyard.sh create [OPTIONS]

Create a dockyard instance: download binaries, install config,
set up systemd service, and start the daemon.

Requires a dockyard.env config file (run gen-env first).

Options:
  --no-systemd    Skip systemd service installation
  --no-start      Don't start the daemon after install
  -h, --help      Show this help

Examples:
  ./dockyard.sh gen-env && sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  DOCKYARD_ENV=./custom.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

# ── Dispatch ─────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    gen-env)
        cmd_gen_env "$@"
        ;;
    create)
        if ! try_load_env; then
            echo "No config found — auto-generating with random networks..."
            cmd_gen_env
            load_env
        fi
        derive_vars
        cmd_create "$@"
        ;;
    enable)
        load_env
        derive_vars
        cmd_enable
        ;;
    disable)
        load_env
        derive_vars
        cmd_disable
        ;;
    start)
        load_env
        derive_vars
        cmd_start
        ;;
    stop)
        load_env
        derive_vars
        cmd_stop
        ;;
    status)
        load_env
        derive_vars
        cmd_status
        ;;
    verify)
        load_env
        derive_vars
        cmd_verify
        ;;
    destroy)
        load_env
        derive_vars
        cmd_destroy "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        ;;
esac

__DOCKYARD_BUNDLED_EOF__
  chmod +x /tmp/dockyard.sh
}

write_helper_scripts() {
  cat > "${DOCKYARD_ROOT}/bin/docker-logs" <<LOGS
#!/bin/bash
exec sudo ${DOCKER} compose -f ${SANDCASTLE_HOME}/docker-compose.yml logs -f "\$@"
LOGS
  chmod +x "${DOCKYARD_ROOT}/bin/docker-logs"
  wrote "${DOCKYARD_ROOT}/bin/docker-logs"
}

write_compose() {
  local DATA_MOUNT="$SANDCASTLE_HOME/data"

  # Derive fixed IPs from the sandcastle-web network subnet.
  # If the network doesn't exist yet (shouldn't happen — created before this),
  # fall back to no fixed IPs and let Docker assign dynamically.
  local NET_PREFIX=""
  local TRAEFIK_IP="" POSTGRES_IP="" WEB_IP="" WORKER_IP=""
  local net_subnet
  net_subnet=$($DOCKER network inspect sandcastle-web \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null) || true
  if [ -n "$net_subnet" ]; then
    # e.g. "10.89.1.0/24" → "10.89.1"
    NET_PREFIX="${net_subnet%.*}"
    TRAEFIK_IP="${NET_PREFIX}.10"
    POSTGRES_IP="${NET_PREFIX}.11"
    WEB_IP="${NET_PREFIX}.12"
    WORKER_IP="${NET_PREFIX}.13"
  fi

  cat > "$SANDCASTLE_HOME/docker-compose.yml" <<COMPOSE
services:
  traefik:
    image: traefik:v3.6
    runtime: runc
    container_name: sandcastle-traefik
    restart: unless-stopped
    ports:
      - "${SANDCASTLE_HTTP_PORT}:80"
      - "${SANDCASTLE_HTTPS_PORT}:443"
      - "${TCP_PORT_MIN}-${TCP_PORT_MAX}:${TCP_PORT_MIN}-${TCP_PORT_MAX}"
    volumes:
      - ${DATA_MOUNT}/traefik/traefik.yml:/etc/traefik/traefik.yml
      - ${DATA_MOUNT}/traefik/dynamic:/data/dynamic:ro
      - ${DATA_MOUNT}/traefik/acme.json:/data/acme.json
      - ${DATA_MOUNT}/traefik/certs:/data/certs:ro
    networks:
      sandcastle-web:
        ipv4_address: ${TRAEFIK_IP}

  postgres:
    image: postgres:18
    runtime: runc
    restart: unless-stopped
    volumes:
      - ${SANDCASTLE_HOME}/data/postgres:/var/lib/postgresql
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
      sandcastle-web:
        ipv4_address: ${POSTGRES_IP}

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
      AR_ENCRYPTION_PRIMARY_KEY: \${AR_ENCRYPTION_PRIMARY_KEY}
      AR_ENCRYPTION_DETERMINISTIC_KEY: \${AR_ENCRYPTION_DETERMINISTIC_KEY}
      AR_ENCRYPTION_KEY_DERIVATION_SALT: \${AR_ENCRYPTION_KEY_DERIVATION_SALT}
      OIDC_PRIVATE_KEY_PEM: \${OIDC_PRIVATE_KEY_PEM:-}
      SANDCASTLE_HOST: \${SANDCASTLE_HOST}
      SANDCASTLE_NAME: \${SANDCASTLE_NAME:-}
      SANDCASTLE_DATA_DIR: ${DATA_MOUNT}
      SANDCASTLE_TLS_MODE: \${SANDCASTLE_TLS_MODE:-letsencrypt}
      SANDCASTLE_ADMIN_USER: \${SANDCASTLE_ADMIN_USER:-admin}
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
      DOCKYARD_POOL_BASE: \${DOCKYARD_POOL_BASE:-10.89.0.0/16}
      DOCKER_SOCK: \${DOCKER_SOCK:-/var/run/docker.sock}
      SANDCASTLE_TCP_PORT_MIN: \${SANDCASTLE_TCP_PORT_MIN:-${TCP_PORT_MIN}}
      SANDCASTLE_TCP_PORT_MAX: \${SANDCASTLE_TCP_PORT_MAX:-${TCP_PORT_MAX}}
      SANDCASTLE_TRAEFIK_CONFIG: ${DATA_MOUNT}/traefik/traefik.yml
      SANDCASTLE_DOCKER_DNS: \${SANDCASTLE_DOCKER_DNS:-}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    networks:
      sandcastle-web:
        ipv4_address: ${WEB_IP}

  worker:
    image: ${APP_IMAGE}
    runtime: runc
    container_name: sandcastle-worker
    command: ["./bin/jobs"]
    group_add:
      - "\${DOCKER_GID:-988}"
    volumes:
      - \${DOCKER_SOCK}:/var/run/docker.sock
      - ${DATA_MOUNT}:${DATA_MOUNT}
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      AR_ENCRYPTION_PRIMARY_KEY: \${AR_ENCRYPTION_PRIMARY_KEY}
      AR_ENCRYPTION_DETERMINISTIC_KEY: \${AR_ENCRYPTION_DETERMINISTIC_KEY}
      AR_ENCRYPTION_KEY_DERIVATION_SALT: \${AR_ENCRYPTION_KEY_DERIVATION_SALT}
      OIDC_PRIVATE_KEY_PEM: \${OIDC_PRIVATE_KEY_PEM:-}
      SANDCASTLE_HOST: \${SANDCASTLE_HOST}
      SANDCASTLE_NAME: \${SANDCASTLE_NAME:-}
      SANDCASTLE_DATA_DIR: ${DATA_MOUNT}
      SANDCASTLE_TLS_MODE: \${SANDCASTLE_TLS_MODE:-letsencrypt}
      DB_HOST: postgres
      DB_USER: sandcastle
      DB_PASSWORD: \${DB_PASSWORD}
      DOCKYARD_POOL_BASE: \${DOCKYARD_POOL_BASE:-10.89.0.0/16}
      SANDCASTLE_TCP_PORT_MIN: \${SANDCASTLE_TCP_PORT_MIN:-${TCP_PORT_MIN}}
      SANDCASTLE_TCP_PORT_MAX: \${SANDCASTLE_TCP_PORT_MAX:-${TCP_PORT_MAX}}
      SANDCASTLE_TRAEFIK_CONFIG: ${DATA_MOUNT}/traefik/traefik.yml
      SANDCASTLE_DOCKER_DNS: \${SANDCASTLE_DOCKER_DNS:-}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    networks:
      sandcastle-web:
        ipv4_address: ${WORKER_IP}

  migrate:
    image: ${APP_IMAGE}
    runtime: runc
    command: ["./bin/rails", "db:prepare"]
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      AR_ENCRYPTION_PRIMARY_KEY: \${AR_ENCRYPTION_PRIMARY_KEY}
      AR_ENCRYPTION_DETERMINISTIC_KEY: \${AR_ENCRYPTION_DETERMINISTIC_KEY}
      AR_ENCRYPTION_KEY_DERIVATION_SALT: \${AR_ENCRYPTION_KEY_DERIVATION_SALT}
      SANDCASTLE_ADMIN_USER: \${SANDCASTLE_ADMIN_USER:-admin}
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
      sandcastle-web:

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
  local admin_user="${SANDCASTLE_ADMIN_USER:-admin}"

  local dy_root="${DOCKYARD_ROOT:-$home/dockyard}"
  local dy_prefix="${DOCKYARD_DOCKER_PREFIX:-sc_}"
  local priv_net="${SANDCASTLE_PRIVATE_NET:-$(pick_private_net)}"
  local _pb="${priv_net%%/*}"; local _pp="${_pb%.*.*}"
  local dy_bridge="${DOCKYARD_BRIDGE_CIDR:-${_pp}.0.1/24}"
  local dy_fixed="${DOCKYARD_FIXED_CIDR:-${_pp}.0.0/24}"
  local dy_pool="${DOCKYARD_POOL_BASE:-${priv_net}}"
  local dy_pool_size="${DOCKYARD_POOL_SIZE:-24}"

  # Auto-derive server name from short hostname (used for Tailscale machine names)
  local sc_name="${SANDCASTLE_NAME:-$(hostname -s 2>/dev/null || true)}"
  sc_name="${sc_name:-sandcastle}"

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

# ─── Server identity ────────────────────────────────────────────────────────
# Human-readable name for this Sandcastle instance.
# Used as the Tailscale machine name for sidecar containers: sc-<name>
# (spaces and special chars are slugified automatically).
SANDCASTLE_NAME=${sc_name}

# ─── Network & TLS ──────────────────────────────────────────────────────────
SANDCASTLE_HOST=${host}
SANDCASTLE_TLS_MODE=${tls_mode}
#ACME_EMAIL=admin@example.com
SANDCASTLE_HTTP_PORT=${http_port}
SANDCASTLE_HTTPS_PORT=${https_port}

# ─── Admin account (required for fresh install) ─────────────────────────────
SANDCASTLE_ADMIN_USER=${admin_user}
SANDCASTLE_ADMIN_EMAIL=${admin_email}
#SANDCASTLE_ADMIN_PASSWORD=changeme
#SANDCASTLE_ADMIN_PASSWORD_FILE=/path/to/password-file
#SANDCASTLE_ADMIN_SSH_KEY=ssh-ed25519 AAAA...

# ─── OAuth (optional — enables "Sign in with …" buttons) ──────────────────
#GITHUB_CLIENT_ID=
#GITHUB_CLIENT_SECRET=
#GOOGLE_CLIENT_ID=
#GOOGLE_CLIENT_SECRET=

# ─── OIDC federation ───────────────────────────────────────────────────────
# Generated automatically on install if unset.
#OIDC_PRIVATE_KEY_PEM=

# ─── Dockyard (Docker + Sysbox) ─────────────────────────────────────────────
DOCKYARD_ROOT=${dy_root}
DOCKYARD_DOCKER_PREFIX=${dy_prefix}

# Private /16 from which all Sandcastle Docker networks are carved.
# Must be RFC 1918: 10.x.x.x, 172.16-31.x.x, or 192.168.x.x.
# Bridge and pool CIDRs are derived from this (override individually below if needed).
SANDCASTLE_PRIVATE_NET=${priv_net}
#DOCKYARD_BRIDGE_CIDR=${dy_bridge}
#DOCKYARD_FIXED_CIDR=${dy_fixed}
#DOCKYARD_POOL_BASE=${dy_pool}
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
      # Do NOT pass --volumes: postgres data lives in a bind-mount under
      # $SANDCASTLE_HOME/data/postgres which must survive uninstall.
      $DOCKER compose -f "$SANDCASTLE_HOME/docker-compose.yml" down --rmi all --remove-orphans 2>/dev/null || true
    fi
    $DOCKER network rm sandcastle-web 2>/dev/null || true

    # Remove sandbox image explicitly (not removed by compose down)
    if [ -n "${SANDBOX_IMAGE:-}" ]; then
      info "Removing sandbox image: $SANDBOX_IMAGE"
      $DOCKER rmi "$SANDBOX_IMAGE" 2>/dev/null || true
    fi
  fi

  # Destroy Dockyard — handle both new layout ($DOCKYARD_ROOT/etc/dockyard.env)
  # and legacy layout ($SANDCASTLE_HOME/etc/dockyard.env with docker-runtime/)
  DOCKYARD_ENV_FILE=""
  if [ -f "$DOCKYARD_ROOT/etc/dockyard.env" ]; then
    DOCKYARD_ENV_FILE="$DOCKYARD_ROOT/etc/dockyard.env"
  elif [ -f "$SANDCASTLE_HOME/etc/dockyard.env" ]; then
    DOCKYARD_ENV_FILE="$SANDCASTLE_HOME/etc/dockyard.env"
  fi

  if [ -n "$DOCKYARD_ENV_FILE" ] || systemctl cat "${DOCKYARD_DOCKER_PREFIX}docker.service" &>/dev/null; then
    info "Destroying Dockyard..."
    if [ -n "$DOCKYARD_ENV_FILE" ] && write_dockyard_sh 2>/dev/null; then
      DOCKYARD_ENV="$DOCKYARD_ENV_FILE" bash /tmp/dockyard.sh destroy --yes --keep-data 2>&1 || true
      rm -f /tmp/dockyard.sh
    else
      systemctl stop "${DOCKYARD_DOCKER_PREFIX}docker" 2>/dev/null || true
      systemctl disable "${DOCKYARD_DOCKER_PREFIX}docker" 2>/dev/null || true
      rm -f "/etc/systemd/system/${DOCKYARD_DOCKER_PREFIX}docker.service"
      systemctl daemon-reload 2>/dev/null || true
      ip link delete "${DOCKYARD_DOCKER_PREFIX}docker0" 2>/dev/null || true
    fi
    # Clean up legacy sc_sysbox.service (old two-service layout)
    if systemctl cat "${DOCKYARD_DOCKER_PREFIX}sysbox.service" &>/dev/null 2>&1; then
      systemctl stop "${DOCKYARD_DOCKER_PREFIX}sysbox" 2>/dev/null || true
      systemctl disable "${DOCKYARD_DOCKER_PREFIX}sysbox" 2>/dev/null || true
      rm -f "/etc/systemd/system/${DOCKYARD_DOCKER_PREFIX}sysbox.service"
      systemctl daemon-reload 2>/dev/null || true
    fi
    # Clean up legacy docker-runtime directory (pre-dockyard layout)
    rm -rf "$SANDCASTLE_HOME/docker-runtime"
    # Clean up legacy socket and docker data at old paths
    rm -f "$SANDCASTLE_HOME/docker.sock"
    rm -rf "$SANDCASTLE_HOME/docker"
    rm -rf "$SANDCASTLE_HOME/sysbox"
    ok "Dockyard destroyed"
  fi

  # Remove user and group
  if id "$SANDCASTLE_USER" &>/dev/null; then
    # Do NOT use -r: the user's home ($SANDCASTLE_HOME) contains data that
    # must be preserved across reinstalls. Directories are cleaned up explicitly below.
    userdel "$SANDCASTLE_USER" 2>/dev/null || true
    ok "Removed user '${SANDCASTLE_USER}'"
  fi
  if getent group "$SANDCASTLE_GROUP" &>/dev/null; then
    groupdel "$SANDCASTLE_GROUP" 2>/dev/null || true
    ok "Removed group '${SANDCASTLE_GROUP}'"
  fi

  # sandcastle-nat.service no longer used (dockyard handles NAT for user-defined networks)

  # Revert UFW firewall rules
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Reverting firewall rules..."
    ufw delete allow "${SANDCASTLE_HTTP_PORT:-80}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${SANDCASTLE_HTTPS_PORT:-443}/tcp" >/dev/null 2>&1 || true
    ufw delete allow 2201:2299/tcp >/dev/null 2>&1 || true
    ok "Firewall rules reverted"
  fi

  # Remove sudoers file
  if [ -f /etc/sudoers.d/sandcastle ]; then
    rm -f /etc/sudoers.d/sandcastle
    ok "Removed sudoers file"
  fi

  # Remove login banner
  if [ -f "/etc/profile.d/sandcastle-banner.sh" ]; then
    rm -f /etc/profile.d/sandcastle-banner.sh
    ok "Removed login banner"
  fi

  # Remove Sandcastle files — keep user data (data/users, data/sandboxes, data/postgres)
  # Preserve data/traefik/acme.json (Let's Encrypt certs) to survive reinstalls.
  rm -f "$SANDCASTLE_HOME/.env"
  rm -f "$SANDCASTLE_HOME/docker-compose.yml"
  rm -rf "$SANDCASTLE_HOME/etc"
  rm -f "$SANDCASTLE_HOME/data/traefik/traefik.yml"
  rm -rf "$SANDCASTLE_HOME/data/traefik/dynamic"
  rm -rf "$SANDCASTLE_HOME/data/traefik/certs"
  rmdir "$SANDCASTLE_HOME/data/traefik" 2>/dev/null || true
  rmdir "$SANDCASTLE_HOME/data" 2>/dev/null || true
  rmdir "$SANDCASTLE_HOME" 2>/dev/null || true
  rm -rf "/run/${DOCKYARD_DOCKER_PREFIX}docker"
  # Clean up dockyard files. If DOCKYARD_ROOT == SANDCASTLE_HOME (new layout),
  # only remove dockyard-specific subdirs to preserve user data.
  if [ "$DOCKYARD_ROOT" = "$SANDCASTLE_HOME" ]; then
    rm -rf "$DOCKYARD_ROOT"/bin
    rm -rf "$DOCKYARD_ROOT"/lib
    rm -rf "$DOCKYARD_ROOT"/run
    rm -rf "$DOCKYARD_ROOT"/log
  else
    rm -rf "$DOCKYARD_ROOT"
  fi

  if [ -d "$SANDCASTLE_HOME/data/users" ] || [ -d "$SANDCASTLE_HOME/data/sandboxes" ] || [ -d "$SANDCASTLE_HOME/data/postgres" ]; then
    warn "User data preserved in $SANDCASTLE_HOME/data/ — remove manually if no longer needed"
  fi
  # Legacy: older installs stored postgres in a Docker named volume 'pgdata'
  if $DOCKER volume inspect pgdata &>/dev/null 2>&1; then
    warn "Legacy Docker volume 'pgdata' still exists — run '$DOCKER volume rm pgdata' to delete it"
  fi

  ok "Sandcastle destroyed"
}

# ═══ cmd_install ═════════════════════════════════════════════════════════════

cmd_install() {
  # Parse install-specific options
  local BACKUP_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-backup)
        BACKUP_FILE="$2"
        [ -n "$BACKUP_FILE" ] || die "--from-backup requires a backup file path"
        [ -f "$BACKUP_FILE" ] || die "Backup file not found: $BACKUP_FILE"
        shift 2
        ;;
      *)
        die "Unknown option for install: $1 (use --from-backup <file>)"
        ;;
    esac
  done

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

  install_prerequisites

  info "Available images (${ARCH}):"
  show_image_info "sandcastle"
  show_image_info "sandcastle-sandbox"
  echo ""

  # ── Install Dockyard ──────────────────────────────────────────────────────

  if [ -S "$DOCKER_SOCK" ]; then
    ok "Dockyard already installed"
    "$DOCKER" compose version &>/dev/null || die "Docker Compose not available — reinstall Dockyard"
  else
    info "Installing Dockyard (Docker + Sysbox)..."
    write_dockyard_sh

    mkdir -p "$SANDCASTLE_HOME/etc"
    local _dy_env="$SANDCASTLE_HOME/etc/dockyard.env"
    cat > "$_dy_env" <<DYEOF
DOCKYARD_ROOT=${DOCKYARD_ROOT}
DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}
DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}
DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}
DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}
DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}
DYEOF
    wrote "$_dy_env"

    DOCKYARD_ENV="$_dy_env" bash /tmp/dockyard.sh create
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
    ufw allow "${TCP_PORT_MIN}:${TCP_PORT_MAX}/tcp" >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "Firewall configured (22, ${SANDCASTLE_HTTP_PORT}, ${SANDCASTLE_HTTPS_PORT}, 2201-2299, ${TCP_PORT_MIN}-${TCP_PORT_MAX})"
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

  # Add sandcastle user to dockyard docker group for socket access
  DOCKER_GROUP="${DOCKYARD_DOCKER_PREFIX}docker"
  if getent group "$DOCKER_GROUP" &>/dev/null; then
    usermod -aG "$DOCKER_GROUP" "$SANDCASTLE_USER"
    ok "Added '${SANDCASTLE_USER}' to group '${DOCKER_GROUP}'"
  else
    # Fallback: detect from socket
    DOCKER_GROUP=$(stat -c '%G' "$DOCKER_SOCK" 2>/dev/null || echo "docker")
    if getent group "$DOCKER_GROUP" &>/dev/null; then
      usermod -aG "$DOCKER_GROUP" "$SANDCASTLE_USER"
      ok "Added '${SANDCASTLE_USER}' to group '${DOCKER_GROUP}'"
    fi
  fi

  # ── Create directories ────────────────────────────────────────────────────

  ensure_dirs

  # ── SSH & sudo setup ──────────────────────────────────────────────────────

  setup_ssh_keys
  setup_passwordless_sudo
  setup_bashrc_path
  setup_login_banner

  # ── Detect fresh install vs upgrade ─────────────────────────────────────

  FRESH_INSTALL=false
  [ ! -f "$SANDCASTLE_HOME/.env" ] && FRESH_INSTALL=true

  # ── Fresh install: validate & generate .env ─────────────────────────────

  if [ "$FRESH_INSTALL" = true ]; then
    [ -z "${SANDCASTLE_HOST:-}" ] && die "SANDCASTLE_HOST is required (set in sandcastle.env)"

    # When restoring from backup, admin credentials come from the backup DB —
    # only SANDCASTLE_HOST (and TLS mode) are required from sandcastle.env.
    if [ -z "$BACKUP_FILE" ]; then
      [ -z "${SANDCASTLE_ADMIN_EMAIL:-}" ] && die "SANDCASTLE_ADMIN_EMAIL is required (set in sandcastle.env)"
      [ -z "${SANDCASTLE_ADMIN_PASSWORD:-}" ] && die "SANDCASTLE_ADMIN_PASSWORD is required (set in sandcastle.env or use SANDCASTLE_ADMIN_PASSWORD_FILE)"
      [ ${#SANDCASTLE_ADMIN_PASSWORD} -lt 6 ] && die "SANDCASTLE_ADMIN_PASSWORD must be at least 6 characters"
    fi

    # SANDCASTLE_SUBNET no longer needed - networks allocated from dockyard pool

    SECRET_KEY_BASE=$(openssl rand -hex 64)
    DOCKER_GID=$(getent group "${DOCKYARD_DOCKER_PREFIX}docker" 2>/dev/null | cut -d: -f3 || stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo "988")

    if [ -n "$BACKUP_FILE" ]; then
      # ── Extract secrets from the backup file ──────────────────────────────
      # Pull just the secrets files from the archive without extracting everything.
      info "Extracting secrets from backup..."
      local _bk_work
      _bk_work=$(mktemp -d)
      trap 'rm -rf "$_bk_work"' EXIT
      tar --use-compress-program=zstd -xf "$BACKUP_FILE" -C "$_bk_work" \
        sandcastle-backup/secrets/rails.secrets \
        sandcastle-backup/secrets/postgres.secrets \
        2>/dev/null \
        || die "Cannot extract secrets from backup — is this a valid Sandcastle backup?"

      # Load DB password from backup
      POSTGRES_SECRETS_FILE="$SANDCASTLE_HOME/data/postgres/.secrets"
      mkdir -p "$SANDCASTLE_HOME/data/postgres"
      cp "$_bk_work/sandcastle-backup/secrets/postgres.secrets" "$POSTGRES_SECRETS_FILE"
      chmod 600 "$POSTGRES_SECRETS_FILE"
      # shellcheck source=/dev/null
      source "$POSTGRES_SECRETS_FILE"
      info "Using database password from backup"

      # Load AR encryption keys from backup
      RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      cp "$_bk_work/sandcastle-backup/secrets/rails.secrets" "$RAILS_SECRETS_FILE"
      chmod 600 "$RAILS_SECRETS_FILE"
      # shellcheck source=/dev/null
      source "$RAILS_SECRETS_FILE"
      info "Using AR encryption keys from backup"

      rm -rf "$_bk_work"
      trap - EXIT
    else
      # ── Normal fresh install: generate or reuse secrets ───────────────────

      # Preserve DB password across reinstalls (user data)
      POSTGRES_SECRETS_FILE="$SANDCASTLE_HOME/data/postgres/.secrets"
      if [ -f "$POSTGRES_SECRETS_FILE" ]; then
        # shellcheck source=/dev/null
        source "$POSTGRES_SECRETS_FILE"
        info "Reusing existing database password"
      else
        DB_PASSWORD=$(openssl rand -hex 32)
        mkdir -p "$SANDCASTLE_HOME/data/postgres"
        echo "DB_PASSWORD=$DB_PASSWORD" > "$POSTGRES_SECRETS_FILE"
        chmod 600 "$POSTGRES_SECRETS_FILE"
        wrote "$POSTGRES_SECRETS_FILE"
      fi

      # Preserve AR encryption keys across reinstalls — required to decrypt
      # encrypted settings (SMTP password, OAuth secrets) stored in the database.
      # Each install gets unique keys; losing them makes encrypted values unrecoverable.
      RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
      if [ -f "$RAILS_SECRETS_FILE" ]; then
        # shellcheck source=/dev/null
        source "$RAILS_SECRETS_FILE"
        info "Reusing existing AR encryption keys"
      else
        mkdir -p "$SANDCASTLE_HOME/data/rails"
        AR_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)
        AR_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)
        AR_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)
        OIDC_PRIVATE_KEY_PEM="${OIDC_PRIVATE_KEY_PEM:-$(openssl genrsa 2048 | base64 -w0)}"
        cat > "$RAILS_SECRETS_FILE" <<SECRETS
AR_ENCRYPTION_PRIMARY_KEY=$AR_ENCRYPTION_PRIMARY_KEY
AR_ENCRYPTION_DETERMINISTIC_KEY=$AR_ENCRYPTION_DETERMINISTIC_KEY
AR_ENCRYPTION_KEY_DERIVATION_SALT=$AR_ENCRYPTION_KEY_DERIVATION_SALT
OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM
SECRETS
        chmod 600 "$RAILS_SECRETS_FILE"
        wrote "$RAILS_SECRETS_FILE"
        warn "AR encryption keys generated. Back them up — losing them makes encrypted settings unrecoverable."
      fi
    fi

    if [ -z "${OIDC_PRIVATE_KEY_PEM:-}" ]; then
      RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      OIDC_PRIVATE_KEY_PEM=$(openssl genrsa 2048 | base64 -w0)
      echo "OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM" >> "$RAILS_SECRETS_FILE"
      chmod 600 "$RAILS_SECRETS_FILE"
      wrote "$RAILS_SECRETS_FILE"
      warn "OIDC signing key generated. Back it up — rotating it requires cloud trust updates."
    fi

    cat > "$SANDCASTLE_HOME/.env" <<EOF
# Sandcastle runtime — generated $(date -Iseconds)
SANDCASTLE_HOME="${SANDCASTLE_HOME}"
SANDCASTLE_NAME="${SANDCASTLE_NAME:-$(hostname -s 2>/dev/null || echo sandcastle)}"
SANDCASTLE_HOST="${SANDCASTLE_HOST}"
SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE}"
SANDCASTLE_USER="${SANDCASTLE_USER}"
SANDCASTLE_GROUP="${SANDCASTLE_GROUP}"
SANDCASTLE_UID="${SANDCASTLE_UID}"
SANDCASTLE_GID="${SANDCASTLE_GID}"
SECRET_KEY_BASE="${SECRET_KEY_BASE}"
AR_ENCRYPTION_PRIMARY_KEY="${AR_ENCRYPTION_PRIMARY_KEY}"
AR_ENCRYPTION_DETERMINISTIC_KEY="${AR_ENCRYPTION_DETERMINISTIC_KEY}"
AR_ENCRYPTION_KEY_DERIVATION_SALT="${AR_ENCRYPTION_KEY_DERIVATION_SALT}"
OIDC_PRIVATE_KEY_PEM="${OIDC_PRIVATE_KEY_PEM}"
DB_PASSWORD="${DB_PASSWORD}"
SANDCASTLE_ADMIN_USER="${SANDCASTLE_ADMIN_USER}"
SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL:-}"
SANDCASTLE_ADMIN_PASSWORD="${SANDCASTLE_ADMIN_PASSWORD:-}"
SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}"
DOCKER_GID="${DOCKER_GID}"
DOCKER_SOCK="${DOCKER_SOCK}"
DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE}"
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

  # Save user-configurable values from sandcastle.env before runtime .env overrides them
  local _user_host="${SANDCASTLE_HOST:-}"
  local _user_tls_mode="${SANDCASTLE_TLS_MODE:-}"

  # shellcheck source=/dev/null
  source "$SANDCASTLE_HOME/.env"

  # Sync user-configurable values: sandcastle.env → runtime .env
  # This allows users to change SANDCASTLE_HOST or TLS mode and re-run install.
  if [ -n "$_user_host" ] && [ "$_user_host" != "$SANDCASTLE_HOST" ]; then
    sed -i "s|^SANDCASTLE_HOST=.*|SANDCASTLE_HOST=${_user_host}|" "$SANDCASTLE_HOME/.env"
    SANDCASTLE_HOST="$_user_host"
    info "Updated SANDCASTLE_HOST to $SANDCASTLE_HOST"
  fi
  if [ -n "$_user_tls_mode" ] && [ "$_user_tls_mode" != "$SANDCASTLE_TLS_MODE" ]; then
    sed -i "s|^SANDCASTLE_TLS_MODE=.*|SANDCASTLE_TLS_MODE=${_user_tls_mode}|" "$SANDCASTLE_HOME/.env"
    SANDCASTLE_TLS_MODE="$_user_tls_mode"
    info "Updated SANDCASTLE_TLS_MODE to $SANDCASTLE_TLS_MODE"
  fi

  # Backfill vars that may be missing in older .env files
  if [ -z "${DOCKER_SOCK:-}" ]; then
    DOCKER_SOCK="${DOCKYARD_ROOT}/run/docker.sock"
    echo "DOCKER_SOCK=$DOCKER_SOCK" >> "$SANDCASTLE_HOME/.env"
  fi
  # Backfill DOCKYARD_POOL_BASE — required so docker-compose passes the correct subnet to Rails
  grep -q '^DOCKYARD_POOL_BASE=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}" >> "$SANDCASTLE_HOME/.env"
  # Backfill SANDCASTLE_NAME — used for Tailscale sidecar machine names (sc-<name>)
  grep -q '^SANDCASTLE_NAME=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "SANDCASTLE_NAME=${SANDCASTLE_NAME:-$(hostname -s 2>/dev/null || echo sandcastle)}" >> "$SANDCASTLE_HOME/.env"
  # Backfill AR encryption keys — generated once, never rotated (losing them breaks encrypted DB values)
  if ! grep -q '^AR_ENCRYPTION_PRIMARY_KEY=' "$SANDCASTLE_HOME/.env" 2>/dev/null; then
    RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
    if [ -f "$RAILS_SECRETS_FILE" ]; then
      # shellcheck source=/dev/null
      source "$RAILS_SECRETS_FILE"
    else
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      AR_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)
      AR_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)
      AR_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)
      cat > "$RAILS_SECRETS_FILE" <<SECRETS
AR_ENCRYPTION_PRIMARY_KEY=$AR_ENCRYPTION_PRIMARY_KEY
AR_ENCRYPTION_DETERMINISTIC_KEY=$AR_ENCRYPTION_DETERMINISTIC_KEY
AR_ENCRYPTION_KEY_DERIVATION_SALT=$AR_ENCRYPTION_KEY_DERIVATION_SALT
SECRETS
      chmod 600 "$RAILS_SECRETS_FILE"
      wrote "$RAILS_SECRETS_FILE"
      warn "AR encryption keys generated. Back them up — losing them makes encrypted settings unrecoverable."
    fi
    cat >> "$SANDCASTLE_HOME/.env" <<ARKEYS
AR_ENCRYPTION_PRIMARY_KEY=$AR_ENCRYPTION_PRIMARY_KEY
AR_ENCRYPTION_DETERMINISTIC_KEY=$AR_ENCRYPTION_DETERMINISTIC_KEY
AR_ENCRYPTION_KEY_DERIVATION_SALT=$AR_ENCRYPTION_KEY_DERIVATION_SALT
ARKEYS
    ok "AR encryption keys backfilled into .env"
  fi
  if ! grep -q '^OIDC_PRIVATE_KEY_PEM=' "$SANDCASTLE_HOME/.env" 2>/dev/null; then
    RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
    if [ -f "$RAILS_SECRETS_FILE" ]; then
      # shellcheck source=/dev/null
      source "$RAILS_SECRETS_FILE"
    fi
    if [ -z "${OIDC_PRIVATE_KEY_PEM:-}" ]; then
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      OIDC_PRIVATE_KEY_PEM=$(openssl genrsa 2048 | base64 -w0)
      echo "OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM" >> "$RAILS_SECRETS_FILE"
      chmod 600 "$RAILS_SECRETS_FILE"
      wrote "$RAILS_SECRETS_FILE"
      warn "OIDC signing key generated. Back it up — rotating it requires cloud trust updates."
    fi
    echo "OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM" >> "$SANDCASTLE_HOME/.env"
    ok "OIDC signing key backfilled into .env"
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
SANDCASTLE_NAME="${SANDCASTLE_NAME:-$(hostname -s 2>/dev/null || echo sandcastle)}"
SANDCASTLE_HOST="${SANDCASTLE_HOST}"
SANDCASTLE_TLS_MODE="${SANDCASTLE_TLS_MODE}"
SANDCASTLE_HTTP_PORT="${SANDCASTLE_HTTP_PORT}"
SANDCASTLE_HTTPS_PORT="${SANDCASTLE_HTTPS_PORT}"
SANDCASTLE_ADMIN_USER="${SANDCASTLE_ADMIN_USER}"
SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL:-}"
SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
DOCKYARD_ROOT="${DOCKYARD_ROOT}"
DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX}"
SANDCASTLE_PRIVATE_NET="${SANDCASTLE_PRIVATE_NET}"
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
      # Detect IP vs hostname for the SAN extension
      local san_type="DNS"
      echo "$SANDCASTLE_HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && san_type="IP"
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$TRAEFIK_DIR/certs/key.pem" -out "$TRAEFIK_DIR/certs/cert.pem" \
        -subj "/CN=$SANDCASTLE_HOST" \
        -addext "subjectAltName=${san_type}:${SANDCASTLE_HOST},IP:127.0.0.1,DNS:localhost" 2>/dev/null
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

  elif [ "$SANDCASTLE_TLS_MODE" = "mkcert" ]; then
    install_mkcert
    local caroot="$SANDCASTLE_HOME/data/traefik/certs"
    CAROOT="$caroot" mkcert -install 2>/dev/null || true
    if [ ! -f "$TRAEFIK_DIR/certs/cert.pem" ]; then
      info "Generating mkcert certificate for $SANDCASTLE_HOST..."
      CAROOT="$caroot" mkcert \
        -cert-file "$TRAEFIK_DIR/certs/cert.pem" \
        -key-file  "$TRAEFIK_DIR/certs/key.pem" \
        "$SANDCASTLE_HOST" "*.${SANDCASTLE_HOST}" localhost 127.0.0.1 ::1
      ok "mkcert certificate generated"
    fi
    cp "$caroot/rootCA.pem" "$TRAEFIK_DIR/certs/rootCA.pem" 2>/dev/null || true
    info "mkcert CA root: $caroot/rootCA.pem"
    info "Install on client machines to trust this server's certificate:"
    info "  macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain rootCA.pem"
    info "  Linux: sudo cp rootCA.pem /usr/local/share/ca-certificates/sandcastle.crt && sudo update-ca-certificates"

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

  if [ "$SANDCASTLE_TLS_MODE" = "selfsigned" ] || [ "$SANDCASTLE_TLS_MODE" = "mkcert" ]; then
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

  chown "${SANDCASTLE_UID}:${SANDCASTLE_GID}" "$TRAEFIK_DIR/traefik.yml"
  chown -R "${SANDCASTLE_UID}:${SANDCASTLE_GID}" "$SANDCASTLE_HOME"/data/traefik/dynamic

  # ── Docker network ────────────────────────────────────────────────────────

  # ── Create sandcastle-web network (allocated from dockyard pool) ────────────
  # Let dockyard allocate the subnet from its address pool (DOCKYARD_POOL_BASE)
  # so dockyard's own iptables rules handle NAT/forwarding automatically.
  # No separate sandcastle-nat service needed.
  if $DOCKER network inspect sandcastle-web &>/dev/null; then
    ok "sandcastle-web network exists"
  else
    $DOCKER network create sandcastle-web >/dev/null
    ok "sandcastle-web network created"
  fi

  # ── Pull images ───────────────────────────────────────────────────────────

  info "Pulling images..."
  $DOCKER pull "$APP_IMAGE" &
  $DOCKER pull "$SANDBOX_IMAGE" &
  $DOCKER pull traefik:v3.6 &
  $DOCKER pull busybox:latest &
  wait
  ok "Images pulled"

  # ── Write PostgreSQL init script ──────────────────────────────────────────

  mkdir -p "$SANDCASTLE_HOME/etc/postgres"
  cat > "$SANDCASTLE_HOME/etc/postgres/init-databases.sh" <<'INITDB'
#!/bin/bash
set -e

# Create additional databases needed by Solid Cache, Queue, Cable, and Errors.
# The primary database (sandcastle_production) is created automatically
# by POSTGRES_DB, but the Solid* gems each need their own database.

for db in sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable sandcastle_production_errors; do
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

  # ── Install prerequisites and sandcastle-admin ────────────────────────────

  install_prerequisites
  write_admin_script

  # ── Start services ────────────────────────────────────────────────────────

  cd "$SANDCASTLE_HOME"

  if [ "$FRESH_INSTALL" = true ] && [ -n "$BACKUP_FILE" ]; then
    # ── Restore from backup ─────────────────────────────────────────────────
    # Start postgres first, restore data, then bring up everything.

    info "Starting PostgreSQL for restore..."
    $DOCKER compose up -d postgres
    local _i
    for _i in $(seq 1 30); do
      $DOCKER compose exec -T postgres \
        pg_isready -U sandcastle -d sandcastle_production &>/dev/null && break
      sleep 2
    done
    ok "PostgreSQL ready"

    # Extract and restore from the backup (db + data + images).
    # Use sandcastle-admin restore for the actual restore logic.
    info "Restoring from backup: $BACKUP_FILE"
    SANDCASTLE_HOME="$SANDCASTLE_HOME" \
      "$SANDCASTLE_HOME/bin/sandcastle-admin" restore "$BACKUP_FILE" \
      --yes --skip-images 2>/dev/null \
      || die "Restore failed — check the backup file and try again"

    # Load snapshot images (docker save/load requires the daemon to be running)
    # The restore command skipped them above; load manually now if present.
    info "Starting Sandcastle..."
    $DOCKER compose up -d

    # Load snapshot images now that the Dockyard daemon is fully up
    local _tmp_bk
    _tmp_bk=$(mktemp -d)
    tar --use-compress-program=zstd -xf "$BACKUP_FILE" -C "$_tmp_bk" \
      sandcastle-backup/images 2>/dev/null || true
    if [ -d "$_tmp_bk/sandcastle-backup/images" ]; then
      info "Loading snapshot Docker images..."
      local _img
      for _img in "$_tmp_bk/sandcastle-backup/images/"*.tar; do
        [ -f "$_img" ] || continue
        info "  Loading $(basename "$_img")..."
        $DOCKER load < "$_img" && ok "  $(basename "$_img")"
      done
    fi
    rm -rf "$_tmp_bk"
    setup_network_isolation
  else
    info "Starting Sandcastle..."
    $DOCKER compose up -d
    setup_network_isolation

    # ── Seed database (fresh install without backup) ──────────────────────

    if [ "$FRESH_INSTALL" = true ]; then
      info "Waiting for app to be ready..."
      local health_url="https://${SANDCASTLE_HOST}:${SANDCASTLE_HTTPS_PORT}/up"
      local app_ready=false
      for i in $(seq 1 30); do
        if curl -sfk "$health_url" >/dev/null 2>&1; then
          app_ready=true
          break
        fi
        sleep 2
      done
      [ "$app_ready" = true ] || die "App did not become ready at $health_url"

      info "Seeding database..."
      $DOCKER compose exec -T \
        -e SANDCASTLE_ADMIN_USER="${SANDCASTLE_ADMIN_USER}" \
        -e SANDCASTLE_ADMIN_EMAIL="${SANDCASTLE_ADMIN_EMAIL}" \
        -e SANDCASTLE_ADMIN_PASSWORD="${SANDCASTLE_ADMIN_PASSWORD}" \
        -e SANDCASTLE_ADMIN_SSH_KEY="${SANDCASTLE_ADMIN_SSH_KEY:-}" \
        web ./bin/rails db:seed
    fi
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
  elif [ "$SANDCASTLE_TLS_MODE" = "mkcert" ]; then
    echo -e "  Dashboard:  ${BLUE}${base_url}${NC} (mkcert cert — install rootCA.pem on clients)"
  else
    echo -e "  Dashboard:  ${BLUE}${base_url}${NC}"
  fi

  if [ "$FRESH_INSTALL" = true ] && [ -n "$BACKUP_FILE" ]; then
    echo ""
    echo -e "  ${GREEN}Restored from backup:${NC} $BACKUP_FILE"
    echo -e "  Log in with your existing credentials."
  elif [ "$FRESH_INSTALL" = true ]; then
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
  echo -e "  Logs:       ${DOCKYARD_ROOT}/bin/docker-logs"

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
  grep -q '^DOCKYARD_POOL_BASE=' "$SANDCASTLE_HOME/.env" 2>/dev/null || \
    echo "DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}" >> "$SANDCASTLE_HOME/.env"
  if ! grep -q '^AR_ENCRYPTION_PRIMARY_KEY=' "$SANDCASTLE_HOME/.env" 2>/dev/null; then
    RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
    if [ -f "$RAILS_SECRETS_FILE" ]; then
      # shellcheck source=/dev/null
      source "$RAILS_SECRETS_FILE"
    else
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      AR_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)
      AR_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)
      AR_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)
      cat > "$RAILS_SECRETS_FILE" <<SECRETS
AR_ENCRYPTION_PRIMARY_KEY=$AR_ENCRYPTION_PRIMARY_KEY
AR_ENCRYPTION_DETERMINISTIC_KEY=$AR_ENCRYPTION_DETERMINISTIC_KEY
AR_ENCRYPTION_KEY_DERIVATION_SALT=$AR_ENCRYPTION_KEY_DERIVATION_SALT
SECRETS
      chmod 600 "$RAILS_SECRETS_FILE"
      wrote "$RAILS_SECRETS_FILE"
      warn "AR encryption keys generated. Back them up — losing them makes encrypted settings unrecoverable."
    fi
    cat >> "$SANDCASTLE_HOME/.env" <<ARKEYS
AR_ENCRYPTION_PRIMARY_KEY=$AR_ENCRYPTION_PRIMARY_KEY
AR_ENCRYPTION_DETERMINISTIC_KEY=$AR_ENCRYPTION_DETERMINISTIC_KEY
AR_ENCRYPTION_KEY_DERIVATION_SALT=$AR_ENCRYPTION_KEY_DERIVATION_SALT
ARKEYS
    ok "AR encryption keys backfilled into .env"
  fi
  if ! grep -q '^OIDC_PRIVATE_KEY_PEM=' "$SANDCASTLE_HOME/.env" 2>/dev/null; then
    RAILS_SECRETS_FILE="$SANDCASTLE_HOME/data/rails/.secrets"
    if [ -f "$RAILS_SECRETS_FILE" ]; then
      # shellcheck source=/dev/null
      source "$RAILS_SECRETS_FILE"
    fi
    if [ -z "${OIDC_PRIVATE_KEY_PEM:-}" ]; then
      mkdir -p "$SANDCASTLE_HOME/data/rails"
      OIDC_PRIVATE_KEY_PEM=$(openssl genrsa 2048 | base64 -w0)
      echo "OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM" >> "$RAILS_SECRETS_FILE"
      chmod 600 "$RAILS_SECRETS_FILE"
      wrote "$RAILS_SECRETS_FILE"
      warn "OIDC signing key generated. Back it up — rotating it requires cloud trust updates."
    fi
    echo "OIDC_PRIVATE_KEY_PEM=$OIDC_PRIVATE_KEY_PEM" >> "$SANDCASTLE_HOME/.env"
    ok "OIDC signing key backfilled into .env"
  fi
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
  $DOCKER compose up -d
  setup_network_isolation
  ok "Services restarted"

  echo ""
  echo -e "${GREEN}  Sandcastle updated!${NC}"

  print_written_files
  echo ""
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

case "$COMMAND" in
  gen-env)    cmd_gen_env ;;
  install)    load_env; derive_vars; cmd_install "$@" ;;
  update)     load_env; derive_vars; cmd_update ;;
  reset)      load_env; derive_vars; cmd_destroy true; cmd_install "$@" ;;
  uninstall)  load_env; derive_vars; cmd_destroy ;;
esac
