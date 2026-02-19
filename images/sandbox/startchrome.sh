#!/bin/bash
# Sandcastle wrapper for Chrome/Chromium — sets up the display and required flags
# so the browser works inside a Docker/Sysbox container with a VNC virtual display.
# Supports both Google Chrome (amd64) and Chromium (arm64).

if [ -x /opt/google/chrome/google-chrome ]; then
    CHROME_BIN=/opt/google/chrome/google-chrome
elif [ -x /usr/bin/chromium ]; then
    CHROME_BIN=/usr/bin/chromium
else
    echo "[sandcastle] No Chrome or Chromium found" >&2
    exit 1
fi

echo "[sandcastle] browser wrapper: DISPLAY=:99, binary=$CHROME_BIN" >&2

mkdir -p /tmp/chrome-config /tmp/chrome-cache

export XDG_CONFIG_HOME=/tmp/chrome-config
export XDG_CACHE_HOME=/tmp/chrome-cache

exec "$CHROME_BIN" \
  --display=:99 \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer \
  "$@"
