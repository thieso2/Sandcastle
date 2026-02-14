#!/usr/bin/env bash
# Build installer.sh from templates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
OUTPUT_FILE="$REPO_ROOT/installer.sh"

echo "Building installer.sh..."

# Function to read and escape a template file for embedding in heredoc
read_template() {
  local file="$1"
  cat "$file"
}

# Read the base installer logic (everything before the first template injection point)
# For now, we'll use a simpler approach: directly modify specific sections of installer.sh

# Create a temporary working copy
TEMP_INSTALLER=$(mktemp)
cp "$OUTPUT_FILE" "$TEMP_INSTALLER"

echo "  → Injecting docker-compose.yml from repo root..."
# Extract docker-compose.yml section and replace it
# This is complex, so for now we'll use a marker-based approach

# For Phase 1: Just validate that critical files match
echo "  → Validating docker/postgres/init-databases.sh..."
if ! diff -q "$REPO_ROOT/docker/postgres/init-databases.sh" <(sed -n '/cat > "\$SANDCASTLE_HOME\/etc\/postgres\/init-databases\.sh" <<.INITDB./,/^INITDB$/p' "$OUTPUT_FILE" | sed '1d;$d') >/dev/null 2>&1; then
  echo "  ⚠️  WARNING: docker/postgres/init-databases.sh differs from embedded version in installer.sh"
  echo "             Run: installer/sync-postgres-init.sh to sync"
fi

echo "  → Validating docker-compose.yml..."
# Extract the docker-compose.yml section from installer.sh and compare with root file
# This is done by finding the heredoc and comparing
INSTALLER_COMPOSE=$(mktemp)
sed -n '/cat > "\$SANDCASTLE_HOME\/docker-compose\.yml" <<COMPOSE$/,/^COMPOSE$/p' "$OUTPUT_FILE" | sed '1d;$d' > "$INSTALLER_COMPOSE"

if ! diff -q "$REPO_ROOT/docker-compose.yml" "$INSTALLER_COMPOSE" >/dev/null 2>&1; then
  echo "  ⚠️  WARNING: docker-compose.yml differs from embedded version in installer.sh"
  echo "             Manual sync required - see installer/build.sh"
  echo ""
  echo "  Differences:"
  diff -u "$REPO_ROOT/docker-compose.yml" "$INSTALLER_COMPOSE" || true
fi

rm -f "$INSTALLER_COMPOSE"

# For now, just copy the current installer.sh as-is
# Future: implement full template replacement
cp "$TEMP_INSTALLER" "$OUTPUT_FILE"
rm -f "$TEMP_INSTALLER"

echo "✓ Build complete: $OUTPUT_FILE"
echo ""
echo "Note: Full template injection not yet implemented."
echo "      To sync files manually:"
echo "      - docker-compose.yml: Update heredoc at line ~396 in installer.sh"
echo "      - init-databases.sh: Update heredoc at line ~1085 in installer.sh"
