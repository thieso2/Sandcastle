#!/usr/bin/env bash
# Build installer.sh from installer.sh.in template
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
TEMPLATE_FILE="$SCRIPT_DIR/installer.sh.in"
OUTPUT_FILE="$REPO_ROOT/installer.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}→${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*" >&2; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
ok() { echo -e "${GREEN}✓${NC} $*" >&2; }

if [ ! -f "$TEMPLATE_FILE" ]; then
  error "Template file not found: $TEMPLATE_FILE"
  error "Run: cp installer.sh installer/installer.sh.in"
  error "Then replace heredocs with @@TEMPLATE:filename@@ markers"
  exit 1
fi

info "Building installer.sh from template..."

# Create temporary output file
TEMP_OUTPUT=$(mktemp)

# Process the template line by line
while IFS= read -r line; do
  # Check for template markers: @@TEMPLATE:filename@@
  if [[ "$line" =~ @@TEMPLATE:([^@]+)@@ ]]; then
    template_file="${BASH_REMATCH[1]}"

    # Determine the full path to the template
    if [[ "$template_file" == /* ]]; then
      # Absolute path from repo root
      full_path="$REPO_ROOT/${template_file#/}"
    elif [[ "$template_file" == templates/* ]]; then
      # Relative to installer/templates/
      full_path="$TEMPLATES_DIR/${template_file#templates/}"
    else
      # Assume it's in templates/
      full_path="$TEMPLATES_DIR/$template_file"
    fi

    if [ ! -f "$full_path" ]; then
      error "Template file not found: $full_path"
      rm -f "$TEMP_OUTPUT"
      exit 1
    fi

    info "  Injecting: $template_file"
    cat "$full_path"
  else
    # Regular line, output as-is
    echo "$line"
  fi
done < "$TEMPLATE_FILE" > "$TEMP_OUTPUT"

# Move to final location
mv "$TEMP_OUTPUT" "$OUTPUT_FILE"
chmod +x "$OUTPUT_FILE"

ok "Built: $OUTPUT_FILE"
echo ""
info "Verify the output and test before committing!"
