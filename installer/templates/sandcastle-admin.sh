#!/bin/bash
# sandcastle-admin — backup and restore a Sandcastle instance
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

confirm() {
  local msg="${1:-Continue?}"
  echo -en "${YELLOW}${msg} [y/N] ${NC}"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
}

# ═══ Load configuration ═══════════════════════════════════════════════════════

SANDCASTLE_HOME="${SANDCASTLE_HOME:-/sandcastle}"

if [ ! -f "$SANDCASTLE_HOME/.env" ]; then
  die "No Sandcastle install found at $SANDCASTLE_HOME (missing .env).
  Set SANDCASTLE_HOME to the correct path if your install is elsewhere."
fi

# shellcheck source=/dev/null
set -a; source "$SANDCASTLE_HOME/.env"; set +a

DOCKYARD_ROOT="${DOCKYARD_ROOT:-$SANDCASTLE_HOME}"
DOCKER="${DOCKYARD_ROOT}/docker-runtime/bin/docker"
COMPOSE_FILE="$SANDCASTLE_HOME/docker-compose.yml"
DATA_DIR="$SANDCASTLE_HOME/data"

[ -f "$COMPOSE_FILE" ] || die "docker-compose.yml not found at $COMPOSE_FILE"
[ -x "$DOCKER" ]       || die "Docker CLI not found at $DOCKER"

# Extract version from APP_IMAGE tag (e.g. ghcr.io/thieso2/sandcastle:v0.2.3 -> 0.2.3)
APP_IMAGE="${APP_IMAGE:-}"
SC_VERSION=$(echo "$APP_IMAGE" | sed 's/.*://' | sed 's/^v//')
SC_VERSION="${SC_VERSION:-unknown}"

# ═══ BTRFS detection ══════════════════════════════════════════════════════════

BTRFS_AVAILABLE=false
if command -v btrfs &>/dev/null; then
  if btrfs subvolume show "$DATA_DIR/users" &>/dev/null 2>&1; then
    BTRFS_AVAILABLE=true
  fi
fi

# ═══ Cleanup helpers ══════════════════════════════════════════════════════════

SNAP_USERS=""
SNAP_SANDBOXES=""
BACKUP_TMPDIR=""

cleanup_backup() {
  if [ -n "${SNAP_USERS}" ]; then
    btrfs subvolume delete "$SNAP_USERS" 2>/dev/null || true
  fi
  if [ -n "${SNAP_SANDBOXES}" ]; then
    btrfs subvolume delete "$SNAP_SANDBOXES" 2>/dev/null || true
  fi
  if [ -n "${BACKUP_TMPDIR}" ]; then
    rm -rf "$BACKUP_TMPDIR" 2>/dev/null || true
  fi
}

# ═══ cmd_backup ═══════════════════════════════════════════════════════════════

cmd_backup() {
  local outfile=""
  local skip_sandbox_volumes=false
  local skip_snapshot_images=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output)            outfile="$2"; shift 2 ;;
      --no-sandbox-volumes)   skip_sandbox_volumes=true; shift ;;
      --no-snapshot-images)   skip_snapshot_images=true; shift ;;
      -h|--help)              backup_usage; exit 0 ;;
      *) die "Unknown option: $1 (try 'sandcastle-admin backup --help')" ;;
    esac
  done

  command -v zstd  &>/dev/null || die "zstd is required. Install with: apt-get install -y zstd"
  command -v rsync &>/dev/null || die "rsync is required. Install with: apt-get install -y rsync"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%d_%H%M%S")
  local filename="sandcastle-backup-${timestamp}-${SC_VERSION}.tar.zst"
  outfile="${outfile:-$(pwd)/${filename}}"

  BACKUP_TMPDIR=$(mktemp -d /tmp/sandcastle-backup-XXXXXX)
  trap 'cleanup_backup' EXIT

  local stagedir="$BACKUP_TMPDIR/sandcastle-backup"
  mkdir -p "$stagedir"/{db,secrets,data/users,data/sandboxes,data/snapshots,images}

  local includes=()

  # ── PostgreSQL dumps ──────────────────────────────────────────────────────

  info "Dumping PostgreSQL databases..."
  local dbs=(
    sandcastle_production
    sandcastle_production_cache
    sandcastle_production_queue
    sandcastle_production_cable
  )
  local pg_user="${DB_USER:-sandcastle}"
  local any_db_dumped=false

  for db in "${dbs[@]}"; do
    info "  Dumping $db..."
    if (cd "$SANDCASTLE_HOME" && "$DOCKER" compose exec -T postgres \
        pg_dump -U "$pg_user" --format=custom "$db") > "$stagedir/db/${db}.pgdump" 2>/dev/null; then
      any_db_dumped=true
    else
      warn "  $db: dump failed or database not found — skipping"
      rm -f "$stagedir/db/${db}.pgdump"
    fi
  done
  if [ "$any_db_dumped" = true ]; then
    includes+=("db")
    ok "PostgreSQL databases dumped"
  else
    warn "No databases were dumped (is postgres running?)"
  fi

  # ── Secrets ───────────────────────────────────────────────────────────────

  info "Backing up secrets..."
  local secrets_found=false

  if [ -f "$DATA_DIR/rails/.secrets" ]; then
    cp "$DATA_DIR/rails/.secrets" "$stagedir/secrets/rails.secrets"
    chmod 600 "$stagedir/secrets/rails.secrets"
    secrets_found=true
  else
    warn "Rails secrets not found at $DATA_DIR/rails/.secrets"
  fi

  if [ -f "$DATA_DIR/postgres/.secrets" ]; then
    cp "$DATA_DIR/postgres/.secrets" "$stagedir/secrets/postgres.secrets"
    chmod 600 "$stagedir/secrets/postgres.secrets"
    secrets_found=true
  else
    warn "Postgres secrets not found at $DATA_DIR/postgres/.secrets"
  fi

  if [ "$secrets_found" = true ]; then
    includes+=("secrets")
    ok "Secrets backed up"
  fi

  # ── BTRFS point-in-time snapshots (optional) ─────────────────────────────

  if [ "$BTRFS_AVAILABLE" = true ]; then
    info "Creating BTRFS read-only snapshots for consistency..."

    if btrfs subvolume snapshot -r "$DATA_DIR/users" \
        "$DATA_DIR/.backup-snap-users-$$" 2>/dev/null; then
      SNAP_USERS="$DATA_DIR/.backup-snap-users-$$"
      info "  Users snapshot: $SNAP_USERS"
    else
      warn "  Users BTRFS snapshot failed — backing up live directory"
    fi

    if btrfs subvolume snapshot -r "$DATA_DIR/sandboxes" \
        "$DATA_DIR/.backup-snap-sandboxes-$$" 2>/dev/null; then
      SNAP_SANDBOXES="$DATA_DIR/.backup-snap-sandboxes-$$"
      info "  Sandboxes snapshot: $SNAP_SANDBOXES"
    else
      warn "  Sandboxes BTRFS snapshot failed — backing up live directory"
    fi
  fi

  local users_src="${SNAP_USERS:-$DATA_DIR/users}"
  local sandboxes_src="${SNAP_SANDBOXES:-$DATA_DIR/sandboxes}"

  # ── User data ─────────────────────────────────────────────────────────────

  info "Copying user data..."
  if [ -d "$users_src" ]; then
    rsync -a "$users_src/" "$stagedir/data/users/"
    includes+=("user_data")
    ok "User data copied"
  else
    warn "User data directory not found: $users_src"
  fi

  # ── Sandbox volumes ───────────────────────────────────────────────────────

  if [ "$skip_sandbox_volumes" = false ]; then
    info "Copying sandbox volumes..."
    if [ -d "$sandboxes_src" ]; then
      rsync -a "$sandboxes_src/" "$stagedir/data/sandboxes/"
      includes+=("sandbox_volumes")
      ok "Sandbox volumes copied"
    else
      warn "Sandboxes directory not found: $sandboxes_src"
    fi
  else
    info "Skipping sandbox volumes (--no-sandbox-volumes)"
  fi

  # ── Snapshot directories ──────────────────────────────────────────────────

  if [ -d "$DATA_DIR/snapshots" ]; then
    info "Copying snapshot directories..."
    rsync -a "$DATA_DIR/snapshots/" "$stagedir/data/snapshots/"
    includes+=("snapshot_dirs")
    ok "Snapshot directories copied"
  fi

  # ── Snapshot Docker images ────────────────────────────────────────────────

  if [ "$skip_snapshot_images" = false ]; then
    info "Saving snapshot Docker images..."
    local snap_images
    snap_images=$("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' \
      | grep '^sc-snap-' || true)

    if [ -n "$snap_images" ]; then
      local saved_count=0
      while IFS= read -r img; do
        local safe_name="${img//[:\/]/-}"
        info "  Saving $img..."
        if "$DOCKER" save "$img" > "$stagedir/images/${safe_name}.tar" 2>/dev/null; then
          saved_count=$((saved_count + 1))
        else
          warn "  Failed to save $img — skipping"
          rm -f "$stagedir/images/${safe_name}.tar"
        fi
      done <<< "$snap_images"
      if [ $saved_count -gt 0 ]; then
        includes+=("snapshot_images")
        ok "$saved_count snapshot image(s) saved"
      fi
    else
      info "No snapshot images found (sc-snap-* repositories)"
    fi
  else
    info "Skipping snapshot images (--no-snapshot-images)"
  fi

  # ── Let's Encrypt certificate ─────────────────────────────────────────────

  if [ -f "$DATA_DIR/traefik/acme.json" ]; then
    mkdir -p "$stagedir/data/traefik"
    cp "$DATA_DIR/traefik/acme.json" "$stagedir/data/traefik/acme.json"
  fi

  # ── Manifest ──────────────────────────────────────────────────────────────

  info "Writing manifest..."

  local user_count sandbox_count snapshot_count
  user_count=$(find "$stagedir/data/users" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)
  sandbox_count=$(find "$stagedir/data/sandboxes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)
  snapshot_count=$(find "$stagedir/data/snapshots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo 0)

  local includes_json=""
  if [ ${#includes[@]} -gt 0 ]; then
    includes_json=$(printf '"%s",' "${includes[@]}")
    includes_json="[${includes_json%,}]"
  else
    includes_json="[]"
  fi

  cat > "$stagedir/manifest.json" <<MANIFEST
{
  "version": "${SC_VERSION}",
  "schema_version": 1,
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "hostname": "$(hostname -s 2>/dev/null || echo unknown)",
  "includes": ${includes_json},
  "user_count": ${user_count},
  "sandbox_count": ${sandbox_count},
  "snapshot_count": ${snapshot_count}
}
MANIFEST
  ok "Manifest written"

  # ── Create archive ────────────────────────────────────────────────────────

  info "Creating archive: $outfile..."
  mkdir -p "$(dirname "$outfile")"
  tar -C "$BACKUP_TMPDIR" --use-compress-program=zstd -caf "$outfile" sandcastle-backup/
  ok "Archive created"

  local size
  size=$(du -sh "$outfile" | cut -f1)

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Backup complete!${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  File:    $outfile"
  echo -e "  Size:    $size"
  cat "$stagedir/manifest.json"
  echo ""
}

# ═══ cmd_restore ══════════════════════════════════════════════════════════════

cmd_restore() {
  local backup_file=""
  local skip_db=false
  local skip_data=false
  local skip_images=false
  local assume_yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-db)      skip_db=true; shift ;;
      --skip-data)    skip_data=true; shift ;;
      --skip-images)  skip_images=true; shift ;;
      -y|--yes)       assume_yes=true; shift ;;
      -h|--help)      restore_usage; exit 0 ;;
      -*)             die "Unknown option: $1 (try 'sandcastle-admin restore --help')" ;;
      *)              backup_file="$1"; shift ;;
    esac
  done

  [ -z "$backup_file" ] && { restore_usage; exit 1; }
  [ -f "$backup_file" ] || die "Backup file not found: $backup_file"

  command -v zstd  &>/dev/null || die "zstd is required. Install with: apt-get install -y zstd"
  command -v rsync &>/dev/null || die "rsync is required. Install with: apt-get install -y rsync"

  BACKUP_TMPDIR=$(mktemp -d /tmp/sandcastle-restore-XXXXXX)
  trap 'cleanup_backup' EXIT

  # ── Extract archive ────────────────────────────────────────────────────────

  info "Extracting backup archive..."
  tar -C "$BACKUP_TMPDIR" --use-compress-program=zstd -xaf "$backup_file"

  local stagedir="$BACKUP_TMPDIR/sandcastle-backup"
  [ -d "$stagedir" ] || die "Invalid backup: missing sandcastle-backup/ directory in archive"
  [ -f "$stagedir/manifest.json" ] || die "Invalid backup: missing manifest.json"

  # ── Read manifest ──────────────────────────────────────────────────────────

  local bkp_version bkp_created bkp_hostname schema_version
  bkp_version=$(grep '"version"'      "$stagedir/manifest.json" | sed 's/.*"version": *"\([^"]*\)".*/\1/' || echo unknown)
  bkp_created=$(grep '"created_at"'   "$stagedir/manifest.json" | sed 's/.*"created_at": *"\([^"]*\)".*/\1/' || echo unknown)
  bkp_hostname=$(grep '"hostname"'    "$stagedir/manifest.json" | sed 's/.*"hostname": *"\([^"]*\)".*/\1/' || echo unknown)
  schema_version=$(grep '"schema_version"' "$stagedir/manifest.json" | sed 's/[^0-9]//g' || echo 0)

  if [ "${schema_version}" != "1" ]; then
    warn "Backup schema version is '${schema_version}' (expected 1) — restore may not work correctly"
  fi

  # ── Preflight ─────────────────────────────────────────────────────────────

  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  Sandcastle Restore — Preflight Check${NC}"
  echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Backup file:     $backup_file"
  echo -e "  Backup version:  $bkp_version"
  echo -e "  Created at:      $bkp_created"
  echo -e "  Source host:     $bkp_hostname"
  echo -e "  Schema version:  $schema_version"
  echo ""
  echo -e "  Will restore:"
  [ "$skip_db" = false ]     && echo -e "    ${GREEN}✓${NC} PostgreSQL databases"
  [ "$skip_db" = true ]      && echo -e "    ${YELLOW}✗${NC} PostgreSQL databases (--skip-db)"
  [ "$skip_data" = false ]   && echo -e "    ${GREEN}✓${NC} User data, sandbox volumes, snapshot dirs"
  [ "$skip_data" = true ]    && echo -e "    ${YELLOW}✗${NC} Filesystem data (--skip-data)"
  [ "$skip_images" = false ] && echo -e "    ${GREEN}✓${NC} Snapshot Docker images"
  [ "$skip_images" = true ]  && echo -e "    ${YELLOW}✗${NC} Snapshot images (--skip-images)"
  echo ""
  echo -e "  ${YELLOW}WARNING: This will OVERWRITE existing data on this machine.${NC}"
  echo -e "  ${YELLOW}         Sandcastle will be stopped and restarted.${NC}"
  echo ""

  if [ "$assume_yes" = false ]; then
    confirm "Proceed with restore?"
  fi

  # 1. Stop Sandcastle ────────────────────────────────────────────────────────

  info "Step 1/7: Stopping Sandcastle..."
  (cd "$SANDCASTLE_HOME" && "$DOCKER" compose down 2>/dev/null) || \
    warn "docker compose down had errors — continuing anyway"
  ok "Sandcastle stopped"

  # 2. Restore secrets ────────────────────────────────────────────────────────

  info "Step 2/7: Restoring secrets..."
  mkdir -p "$DATA_DIR/rails" "$DATA_DIR/postgres"

  if [ -f "$stagedir/secrets/rails.secrets" ]; then
    cp "$stagedir/secrets/rails.secrets" "$DATA_DIR/rails/.secrets"
    chmod 600 "$DATA_DIR/rails/.secrets"

    # Update .env with restored AR encryption keys
    set -a
    # shellcheck source=/dev/null
    source "$DATA_DIR/rails/.secrets"
    set +a

    if [ -f "$SANDCASTLE_HOME/.env" ]; then
      sed -i "s|^AR_ENCRYPTION_PRIMARY_KEY=.*|AR_ENCRYPTION_PRIMARY_KEY=${AR_ENCRYPTION_PRIMARY_KEY:-}|" \
        "$SANDCASTLE_HOME/.env"
      sed -i "s|^AR_ENCRYPTION_DETERMINISTIC_KEY=.*|AR_ENCRYPTION_DETERMINISTIC_KEY=${AR_ENCRYPTION_DETERMINISTIC_KEY:-}|" \
        "$SANDCASTLE_HOME/.env"
      sed -i "s|^AR_ENCRYPTION_KEY_DERIVATION_SALT=.*|AR_ENCRYPTION_KEY_DERIVATION_SALT=${AR_ENCRYPTION_KEY_DERIVATION_SALT:-}|" \
        "$SANDCASTLE_HOME/.env"
    fi
    ok "Rails secrets restored"
  else
    warn "No rails secrets in backup — Rails encrypted columns may be unreadable"
  fi

  if [ -f "$stagedir/secrets/postgres.secrets" ]; then
    cp "$stagedir/secrets/postgres.secrets" "$DATA_DIR/postgres/.secrets"
    chmod 600 "$DATA_DIR/postgres/.secrets"

    # Update .env with restored DB password
    local saved_db_password=""
    saved_db_password=$(grep '^DB_PASSWORD=' "$stagedir/secrets/postgres.secrets" \
      | cut -d= -f2- || true)
    if [ -n "$saved_db_password" ] && [ -f "$SANDCASTLE_HOME/.env" ]; then
      sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${saved_db_password}|" "$SANDCASTLE_HOME/.env"
    fi
    ok "Postgres secrets restored"
  else
    warn "No postgres secrets in backup — using current DB password"
  fi

  # Reload .env after updating it
  set -a
  # shellcheck source=/dev/null
  source "$SANDCASTLE_HOME/.env"
  set +a

  # 3. Restore database ────────────────────────────────────────────────────────

  if [ "$skip_db" = false ] && [ -d "$stagedir/db" ]; then
    info "Step 3/7: Restoring PostgreSQL databases..."

    info "  Starting PostgreSQL..."
    (cd "$SANDCASTLE_HOME" && "$DOCKER" compose up -d postgres)

    # Wait for postgres to become healthy
    local retries=30
    while [ $retries -gt 0 ]; do
      if (cd "$SANDCASTLE_HOME" && "$DOCKER" compose exec -T postgres \
          pg_isready -U sandcastle) &>/dev/null; then
        break
      fi
      sleep 2
      retries=$((retries - 1))
    done
    [ $retries -eq 0 ] && die "PostgreSQL did not become ready within 60 seconds"
    ok "  PostgreSQL is ready"

    local pg_user="${DB_USER:-sandcastle}"

    for pgdump in "$stagedir"/db/*.pgdump; do
      [ -f "$pgdump" ] || continue
      local db
      db=$(basename "$pgdump" .pgdump)
      info "  Restoring $db..."

      # Ensure the database exists (ignore error if it already does)
      (cd "$SANDCASTLE_HOME" && "$DOCKER" compose exec -T postgres \
        psql -U "$pg_user" -c "CREATE DATABASE \"$db\";" 2>/dev/null) || true

      # Restore the dump (pg_restore reads from stdin via -T)
      if (cd "$SANDCASTLE_HOME" && "$DOCKER" compose exec -T postgres \
          pg_restore -U "$pg_user" --clean --if-exists \
          --no-privileges --no-owner -d "$db") < "$pgdump"; then
        ok "  $db restored"
      else
        warn "  $db: pg_restore reported errors (may be non-fatal, continuing)"
      fi
    done

    # 4. Run migrations ─────────────────────────────────────────────────────────

    info "Step 4/7: Running database migrations..."
    (cd "$SANDCASTLE_HOME" && "$DOCKER" compose run --rm --no-deps migrate) || \
      warn "Migrations had errors — check 'docker compose logs' manually"
    ok "Migrations complete"
  else
    info "Step 3/7: Skipping database restore (--skip-db)"
    info "Step 4/7: Skipping migrations (--skip-db)"
  fi

  # 5. Restore filesystem data ─────────────────────────────────────────────────

  if [ "$skip_data" = false ]; then
    info "Step 5/7: Restoring filesystem data..."

    if [ -d "$stagedir/data/users" ]; then
      info "  Restoring user data..."
      mkdir -p "$DATA_DIR/users"
      rsync -a --delete "$stagedir/data/users/" "$DATA_DIR/users/"
      ok "  User data restored"
    fi

    if [ -d "$stagedir/data/sandboxes" ]; then
      info "  Restoring sandbox volumes..."
      mkdir -p "$DATA_DIR/sandboxes"
      rsync -a --delete "$stagedir/data/sandboxes/" "$DATA_DIR/sandboxes/"
      ok "  Sandbox volumes restored"
    fi

    if [ -d "$stagedir/data/snapshots" ]; then
      info "  Restoring snapshot directories..."
      mkdir -p "$DATA_DIR/snapshots"
      rsync -a --delete "$stagedir/data/snapshots/" "$DATA_DIR/snapshots/"
      ok "  Snapshot directories restored"
    fi

    # Restore acme.json if present (nice-to-have)
    if [ -f "$stagedir/data/traefik/acme.json" ]; then
      mkdir -p "$DATA_DIR/traefik"
      cp "$stagedir/data/traefik/acme.json" "$DATA_DIR/traefik/acme.json"
      ok "  Let's Encrypt certificate restored"
    fi
  else
    info "Step 5/7: Skipping filesystem data (--skip-data)"
  fi

  # 6. Load snapshot images ────────────────────────────────────────────────────

  if [ "$skip_images" = false ] && [ -d "$stagedir/images" ]; then
    local tar_count
    tar_count=$(find "$stagedir/images" -name '*.tar' | wc -l)

    if [ "$tar_count" -gt 0 ]; then
      info "Step 6/7: Loading $tar_count snapshot image(s)..."
      for tar_file in "$stagedir"/images/*.tar; do
        [ -f "$tar_file" ] || continue
        info "  Loading $(basename "$tar_file")..."
        "$DOCKER" load < "$tar_file" || warn "  Failed to load $(basename "$tar_file")"
      done
      ok "Snapshot images loaded"
    else
      info "Step 6/7: No snapshot images in backup"
    fi
  else
    info "Step 6/7: Skipping snapshot images"
  fi

  # 7. Start Sandcastle ────────────────────────────────────────────────────────

  info "Step 7/7: Starting Sandcastle..."
  (cd "$SANDCASTLE_HOME" && "$DOCKER" compose up -d)
  ok "Sandcastle started"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Restore complete!${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo ""
}

# ═══ Help ═════════════════════════════════════════════════════════════════════

backup_usage() {
  cat <<'USAGE'
Usage: sandcastle-admin backup [OPTIONS]

Create a full backup of a running Sandcastle instance.
Sandcastle can stay online during backup.

Options:
  -o, --output <path>       Output file path
                            (default: ./sandcastle-backup-<timestamp>-<version>.tar.zst)
  --no-sandbox-volumes      Skip sandbox persistent volumes (/data/sandboxes/*/vol)
  --no-snapshot-images      Skip snapshot Docker images (docker save sc-snap-*)
  -h, --help                Show this help

Archive layout:
  sandcastle-backup/
  ├── manifest.json
  ├── db/                   PostgreSQL custom-format dumps
  ├── secrets/              Rails AR encryption keys + DB password
  ├── data/                 User homes, sandbox volumes, snapshot dirs
  └── images/               Snapshot Docker image tarballs

Examples:
  sandcastle-admin backup
  sandcastle-admin backup --output /backups/pre-upgrade.tar.zst
  sandcastle-admin backup --no-snapshot-images
USAGE
}

restore_usage() {
  cat <<'USAGE'
Usage: sandcastle-admin restore <backup-file.tar.zst> [OPTIONS]

Restore a Sandcastle instance from a backup.
Sandcastle will be stopped and restarted automatically.

Options:
  --skip-db          Skip database restore and migrations
  --skip-data        Skip filesystem data restore (user homes, volumes)
  --skip-images      Skip loading snapshot Docker images
  -y, --yes          Skip the confirmation prompt
  -h, --help         Show this help

Restore order:
  1. Stop Sandcastle
  2. Restore secrets (AR encryption keys, DB password)
  3. Restore databases (pg_restore --clean)
  4. Run migrations (rails db:prepare)
  5. Restore filesystem data
  6. Load snapshot images
  7. Start Sandcastle

Cross-version restores: step 4 runs all pending migrations to bring
the schema to the current version after the data is in place.

Examples:
  sandcastle-admin restore sandcastle-backup-2026-03-01_120000-0.2.3.tar.zst
  sandcastle-admin restore backup.tar.zst --skip-images --yes
USAGE
}

usage() {
  cat <<'USAGE'
Usage: sandcastle-admin <command> [options]

Sandcastle instance management tool.

Commands:
  backup    Create a full backup of the Sandcastle instance
  restore   Restore from a backup file
  help      Show this help

Run 'sandcastle-admin <command> --help' for command-specific options.

Environment:
  SANDCASTLE_HOME   Installation directory (default: /sandcastle)
USAGE
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  backup)          cmd_backup "$@" ;;
  restore)         cmd_restore "$@" ;;
  help|-h|--help)  usage ;;
  *) error "Unknown command: $COMMAND"; echo ""; usage; exit 1 ;;
esac
