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

DOCKYARD_ROOT="${DOCKYARD_ROOT:-$SANDCASTLE_HOME}"
DOCKER="${DOCKYARD_ROOT}/docker-runtime/bin/docker"
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
  trap 'rm -rf "$work_dir"' EXIT

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
  trap 'rm -rf "$work_dir"' EXIT

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

# ═══ Help ════════════════════════════════════════════════════════════════════

cmd_help() {
  cat <<'USAGE'
Usage: sandcastle-admin <command> [options]

Commands:
  backup     Create a full backup of this Sandcastle instance
  restore    Restore a Sandcastle instance from a backup file
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
USAGE
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  backup)         cmd_backup "$@" ;;
  restore)        cmd_restore "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "Unknown command: $COMMAND — run 'sandcastle-admin help'" ;;
esac
