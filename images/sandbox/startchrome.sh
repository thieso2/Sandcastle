#!/bin/bash
# Launch Google Chrome on the virtual display (:99, started by entrypoint.sh).
# Uses /tmp for config/cache so it works without a persistent home dir.

mkdir -p /tmp/chrome-config /tmp/chrome-cache

export XDG_CONFIG_HOME=/tmp/chrome-config
export XDG_CACHE_HOME=/tmp/chrome-cache

exec google-chrome \
  --display=:99 \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer \
  "$@"
