#!/bin/bash
# Sandcastle wrapper for Google Chrome — sets up the display and required flags
# so Chrome works inside a Docker/Sysbox container with a VNC virtual display.
echo "[sandcastle] google-chrome wrapper: setting DISPLAY=:99 and required Docker flags" >&2

mkdir -p /tmp/chrome-config /tmp/chrome-cache

export XDG_CONFIG_HOME=/tmp/chrome-config
export XDG_CACHE_HOME=/tmp/chrome-cache

# Call the real binary directly to avoid recursion (this script shadows
# /usr/bin/google-chrome via /usr/local/bin which is earlier in PATH).
exec /opt/google/chrome/google-chrome \
  --display=:99 \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer \
  "$@"
