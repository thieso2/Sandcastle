#!/bin/bash
# sandcastle-admin — backup and restore tool for Sandcastle
# Installed at $SANDCASTLE_HOME/bin/sandcastle-admin
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

# ═══ Config ═══════════════════════════════════════════════════════════════════

SANDCASTLE_HOME="${SANDCASTLE_HOME:-/sandcastle}"
DOCKER="${SANDCASTLE_HOME}/docker-runtime/bin/docker"
SCHEMA_VERSION="1"

# ═══ Usage ════════════════════════════════════════════════════════════════════

usage() {
  cat <<'USAGE'
Usage: sandcastle-admin <command> [options]

Commands:
  backup     Create a full backup of Sandcastle data
  restore    Restore Sandcastle from a backup archive
  help       Show this help message

Backup options:
  -o, --output <file>   Output archive path (default: sandcastle-backup-<date>.tar.zst)

Restore options:
  <file>                Path to backup archive (required)

Examples:
  sandcastle-admin backup
  sandcastle-admin backup --output /tmp/my-backup.tar.zst
  sandcastle-admin restore /tmp/sandcastle-backup-2026-03-01.tar.zst
USAGE
}

# ═══ Helpers ═════════════════════════════════════════════════════════════════

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This command must be run as root (use sudo)"
}

require_docker() {
  [ -x "$DOCKER" ] || die "Docker not found at $DOCKER — is Sandcastle installed?"
  "$DOCKER" info &>/dev/null || die "Docker daemon not running"
}

check_prerequisites() {
  local missing=()
  command -v zstd &>/dev/null || missing+=("zstd")
  command -v rsync &>/dev/null || missing+=("rsync")

  if [ ${#missing[@]} -gt 0 ]; then
    info "Installing missing prerequisites: ${missing[*]}..."
    if apt-get install -y "${missing[@]}" >/dev/null 2>&1; then
      ok "Prerequisites installed: ${missing[*]}"
    else
      warn "Failed to install ${missing[*]} — backup/restore may not work"
    fi
  fi
}

# ═══ cmd_backup ═══════════════════════════════════════════════════════════════

cmd_backup() {
  local output=""

  # Parse options
  while [ $# -gt 0 ]; do
    case "$1" in
      --output|-o)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          die "--output requires an argument"
        fi
        output="$2"
        shift 2
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        die "Unexpected argument: $1"
        ;;
    esac
  done

  if [ -z "$output" ]; then
    output="$(pwd)/sandcastle-backup-$(date +%Y-%m-%d-%H%M%S).tar.zst"
  fi

  require_root
  require_docker
  check_prerequisites

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  info "Creating backup at: $output"

  # ── Quiesce BTRFS subvolumes (if applicable) ─────────────────────────────

  local bk_dir="$tmp_dir/backup"
  mkdir -p "$bk_dir"

  # ── Write manifest ────────────────────────────────────────────────────────

  cat > "$bk_dir/manifest.json" <<MANIFEST
{
  "schema_version": "${SCHEMA_VERSION}",
  "created_at": "$(date -Iseconds)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "sandcastle_home": "${SANDCASTLE_HOME}"
}
MANIFEST

  # ── Backup secrets ────────────────────────────────────────────────────────

  mkdir -p "$bk_dir/secrets"

  if [ -f "$SANDCASTLE_HOME/data/postgres/.secrets" ]; then
    cp "$SANDCASTLE_HOME/data/postgres/.secrets" "$bk_dir/secrets/postgres.secrets"
    ok "Backed up postgres secrets"
  else
    warn "No postgres secrets file found — backup may be incomplete"
  fi

  if [ -f "$SANDCASTLE_HOME/data/rails/.secrets" ]; then
    cp "$SANDCASTLE_HOME/data/rails/.secrets" "$bk_dir/secrets/rails.secrets"
    ok "Backed up rails secrets"
  else
    warn "No rails secrets file found — backup may be incomplete"
  fi

  # ── Backup database ───────────────────────────────────────────────────────

  mkdir -p "$bk_dir/databases"

  info "Backing up databases..."

  # Wait for postgres to be ready
  local pg_ready=false
  for i in $(seq 1 30); do
    if "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
        pg_isready -U sandcastle -d sandcastle_production &>/dev/null; then
      pg_ready=true
      break
    fi
    sleep 1
  done

  if [ "$pg_ready" = true ]; then
    ok "PostgreSQL ready"

    for db in sandcastle_production sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable; do
      if "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
          psql -U sandcastle -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$db" 2>/dev/null; then
        info "Dumping database: $db"
        if "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
            pg_dump -U sandcastle -Fc "$db" > "$bk_dir/databases/${db}.dump"; then
          ok "Dumped $db"
        else
          warn "Failed to dump $db"
        fi
      fi
    done
  else
    warn "PostgreSQL not ready after 30s — skipping database backup"
  fi

  # ── Backup user data ──────────────────────────────────────────────────────

  mkdir -p "$bk_dir/data"

  info "Backing up user data..."
  if [ -d "$SANDCASTLE_HOME/data/users" ]; then
    rsync -a --delete "$SANDCASTLE_HOME/data/users/" "$bk_dir/data/users/"
    ok "Backed up users directory"
  fi

  if [ -d "$SANDCASTLE_HOME/data/sandboxes" ]; then
    rsync -a --delete "$SANDCASTLE_HOME/data/sandboxes/" "$bk_dir/data/sandboxes/"
    ok "Backed up sandboxes directory"
  fi

  if [ -d "$SANDCASTLE_HOME/data/snapshots" ]; then
    rsync -a --delete "$SANDCASTLE_HOME/data/snapshots/" "$bk_dir/data/snapshots/"
    ok "Backed up snapshots directory"
  fi

  # ── Backup snapshot Docker images ─────────────────────────────────────────

  mkdir -p "$bk_dir/images"

  local snapshot_images
  snapshot_images=$("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep '^sandcastle-snapshot:' || true)

  if [ -n "$snapshot_images" ]; then
    info "Saving snapshot Docker images..."
    # shellcheck disable=SC2086
    if "$DOCKER" save $snapshot_images > "$bk_dir/images/snapshots.tar"; then
      ok "Saved snapshot images"
    else
      warn "Failed to save snapshot images"
    fi
  else
    info "No snapshot images to backup"
  fi

  # ── Create archive ────────────────────────────────────────────────────────

  info "Creating archive (this may take a while)..."
  tar -C "$tmp_dir" -cf - backup | zstd -T0 -3 > "$output"
  ok "Backup created: $output ($(du -sh "$output" | cut -f1))"
}

# ═══ cmd_restore ═════════════════════════════════════════════════════════════

cmd_restore() {
  local backup_file="${1:-}"

  if [ -z "$backup_file" ]; then
    die "Usage: sandcastle-admin restore <backup-file>"
  fi

  [ -f "$backup_file" ] || die "Backup file not found: $backup_file"

  require_root
  require_docker
  check_prerequisites

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  info "Extracting backup: $backup_file"
  zstd -d "$backup_file" --stdout | tar -C "$tmp_dir" -xf -

  local bk_dir="$tmp_dir/backup"
  [ -d "$bk_dir" ] || die "Invalid backup archive — missing backup/ directory"
  [ -f "$bk_dir/manifest.json" ] || die "Invalid backup archive — missing manifest.json"

  # ── Validate schema version ───────────────────────────────────────────────

  local schema_ver
  schema_ver=$(grep -o '"schema_version": *"[^"]*"' "$bk_dir/manifest.json" \
    | grep -o '"[^"]*"$' | tr -d '"' || echo "")

  if [ "$schema_ver" != "$SCHEMA_VERSION" ]; then
    die "Unsupported backup schema version: $schema_ver (expected: $SCHEMA_VERSION)"
  fi

  info "Backup schema version: $schema_ver"
  info "Backup created: $(grep -o '"created_at": *"[^"]*"' "$bk_dir/manifest.json" \
    | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")"

  # ── Restore secrets ───────────────────────────────────────────────────────

  if [ -f "$bk_dir/secrets/postgres.secrets" ]; then
    mkdir -p "$SANDCASTLE_HOME/data/postgres"
    cp "$bk_dir/secrets/postgres.secrets" "$SANDCASTLE_HOME/data/postgres/.secrets"
    chmod 600 "$SANDCASTLE_HOME/data/postgres/.secrets"
    ok "Restored postgres secrets"
  fi

  if [ -f "$bk_dir/secrets/rails.secrets" ]; then
    mkdir -p "$SANDCASTLE_HOME/data/rails"
    cp "$bk_dir/secrets/rails.secrets" "$SANDCASTLE_HOME/data/rails/.secrets"
    chmod 600 "$SANDCASTLE_HOME/data/rails/.secrets"
    ok "Restored rails secrets"
  fi

  # ── Restore user data ─────────────────────────────────────────────────────

  if [ -d "$bk_dir/data/users" ]; then
    info "Restoring users directory..."
    mkdir -p "$SANDCASTLE_HOME/data/users"
    rsync -a --delete "$bk_dir/data/users/" "$SANDCASTLE_HOME/data/users/"
    ok "Restored users directory"
  fi

  if [ -d "$bk_dir/data/sandboxes" ]; then
    info "Restoring sandboxes directory..."
    mkdir -p "$SANDCASTLE_HOME/data/sandboxes"
    rsync -a --delete "$bk_dir/data/sandboxes/" "$SANDCASTLE_HOME/data/sandboxes/"
    ok "Restored sandboxes directory"
  fi

  if [ -d "$bk_dir/data/snapshots" ]; then
    info "Restoring snapshots directory..."
    mkdir -p "$SANDCASTLE_HOME/data/snapshots"
    rsync -a --delete "$bk_dir/data/snapshots/" "$SANDCASTLE_HOME/data/snapshots/"
    ok "Restored snapshots directory"
  fi

  # ── Restore databases ─────────────────────────────────────────────────────

  if [ -d "$bk_dir/databases" ] && ls "$bk_dir/databases"/*.dump &>/dev/null; then
    info "Waiting for PostgreSQL to be ready..."
    local pg_ready=false
    for i in $(seq 1 60); do
      if "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
          pg_isready -U sandcastle -d sandcastle_production &>/dev/null; then
        pg_ready=true
        break
      fi
      sleep 1
    done

    if [ "$pg_ready" != true ]; then
      error "PostgreSQL not ready after 60s"
      exit 1
    fi

    ok "PostgreSQL ready"

    for dump_file in "$bk_dir/databases"/*.dump; do
      local db
      db=$(basename "$dump_file" .dump)
      info "Restoring database: $db"

      # Create database if it doesn't exist
      if ! "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
          psql -U sandcastle -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$db" 2>/dev/null; then
        if ! "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
            createdb -U sandcastle "$db"; then
          error "Failed to create database: $db"
          exit 1
        fi
        ok "Created database: $db"
      else
        # Drop and recreate to ensure clean restore
        if ! "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
            psql -U sandcastle -c "DROP DATABASE \"$db\";" postgres; then
          error "Failed to drop database: $db"
          exit 1
        fi
        if ! "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
            createdb -U sandcastle "$db"; then
          error "Failed to recreate database: $db"
          exit 1
        fi
      fi

      if ! "$DOCKER" compose -f "$SANDCASTLE_HOME/docker-compose.yml" exec -T postgres \
          pg_restore -U sandcastle -d "$db" < "$dump_file"; then
        error "Failed to restore database: $db"
        exit 1
      fi
      ok "Restored database: $db"
    done
  fi

  # ── Restore snapshot Docker images ────────────────────────────────────────

  if [ -f "$bk_dir/images/snapshots.tar" ]; then
    info "Loading snapshot Docker images..."
    if "$DOCKER" load < "$bk_dir/images/snapshots.tar"; then
      ok "Loaded snapshot images"
    else
      warn "Failed to load some snapshot images"
    fi
  fi

  ok "Restore complete"
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  backup)   cmd_backup "$@" ;;
  restore)  cmd_restore "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die "Unknown command: $COMMAND (use 'help' for usage)" ;;
esac
