#!/usr/bin/env bash
# Sync source files into installer.sh heredocs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/installer.sh"

echo "Syncing files into installer.sh..."

# Function to replace a heredoc section in installer.sh
replace_heredoc() {
  local start_pattern="$1"
  local end_marker="$2"
  local source_file="$3"
  local temp_file=$(mktemp)

  # Find line numbers
  start_line=$(grep -n "$start_pattern" "$INSTALLER" | cut -d: -f1)
  end_line=$(awk "/$end_marker/{if (NR>$start_line) {print NR; exit}}" "$INSTALLER")

  if [ -z "$start_line" ] || [ -z "$end_line" ]; then
    echo "ERROR: Could not find heredoc for $source_file"
    return 1
  fi

  # Build new file: before + new content + after
  head -n "$start_line" "$INSTALLER" > "$temp_file"
  cat "$source_file" >> "$temp_file"
  echo "$end_marker" >> "$temp_file"
  tail -n +"$((end_line + 1))" "$INSTALLER" >> "$temp_file"

  mv "$temp_file" "$INSTALLER"
  echo "  ✓ Synced $source_file"
}

# Sync docker-compose.yml
echo "  → Syncing docker-compose.yml..."
# Find the heredoc: cat > "$SANDCASTLE_HOME/docker-compose.yml" <<COMPOSE
# Replace everything between that and COMPOSE
replace_heredoc \
  'cat > "\$SANDCASTLE_HOME/docker-compose.yml" <<COMPOSE' \
  'COMPOSE' \
  "$REPO_ROOT/docker-compose.yml"

# Sync init-databases.sh
echo "  → Syncing docker/postgres/init-databases.sh..."
replace_heredoc \
  'cat > "\$SANDCASTLE_HOME/etc/postgres/init-databases.sh" <<'"'"'INITDB'"'"'' \
  'INITDB' \
  "$REPO_ROOT/docker/postgres/init-databases.sh"

echo ""
echo "✓ Files synced successfully!"
echo "  Remember to commit installer.sh after verifying changes."
