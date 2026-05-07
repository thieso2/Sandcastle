#!/bin/sh
# Sandcastle login banner

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -n "${SANDCASTLE_BANNER_SHOWN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
export SANDCASTLE_BANNER_SHOWN=1

SETTINGS_FILE="/etc/sandcastle/settings"

setting_value() {
  key=$1
  default=$2

  if [ -f "$SETTINGS_FILE" ]; then
    value=$(
      awk -F': ' -v key="$key" '$1 == key { print substr($0, index($0, ": ") + 2); exit }' \
        "$SETTINGS_FILE" 2>/dev/null
    )
    [ -n "$value" ] && {
      printf '%s\n' "$value"
      return 0
    }
  fi

  printf '%s\n' "$default"
}

VERSION=$(setting_value version unknown)
HOST=$(setting_value host unknown)
TLS_MODE=$(setting_value "tls mode" unknown)
HOME_DIR=$(setting_value home /sandcastle)

print_setting() {
  printf '  %-10s %s\n' "$1" "$2"
}

cat << 'EOF'

    |>  |>
   _|_ _|_
  |_|_|_|_|
  |       |
 ~|_[#]___|~     sandcastle
 ~~~~~~~~~~~     every tide, a fresh shore

EOF

print_setting "version" "$VERSION"
print_setting "host" "$HOST"
print_setting "tls" "$TLS_MODE"
print_setting "home" "$HOME_DIR"
print_setting "settings" "$SETTINGS_FILE"
echo ""
