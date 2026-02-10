#!/bin/bash
# Build the sandcastle-sandbox Incus image from Ubuntu 24.04 cloud image.
# Usage:
#   bash images/sandbox/build-image.sh          # full image
#   bash images/sandbox/build-image.sh --min    # minimal image (no build-essential, aggressive cleanup)
set -euo pipefail

MIN_MODE=false
if [[ "${1:-}" == "--min" ]]; then
  MIN_MODE=true
fi

if $MIN_MODE; then
  IMAGE_ALIAS="sandcastle-min"
else
  IMAGE_ALIAS="sandcastle-sandbox"
fi
BUILD_INSTANCE="build-sandbox-image"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building ${IMAGE_ALIAS} image ==="

# Clean up any previous build instance
if incus info "$BUILD_INSTANCE" &>/dev/null; then
  echo "Cleaning up previous build instance..."
  incus stop "$BUILD_INSTANCE" --force 2>/dev/null || true
  incus delete "$BUILD_INSTANCE" --force
fi

# Launch a fresh Ubuntu 24.04 VM-like container
echo "Launching build instance..."
incus launch images:ubuntu/24.04/cloud "$BUILD_INSTANCE" \
  --profile default \
  --config security.nesting=true \
  --config security.syscalls.intercept.mknod=true \
  --config security.syscalls.intercept.setxattr=true

echo "Waiting for instance to be ready..."
sleep 5

# Wait for cloud-init to finish
incus exec "$BUILD_INSTANCE" -- cloud-init status --wait 2>/dev/null || sleep 10

echo "Installing packages..."
incus exec "$BUILD_INSTANCE" -- bash -c "
  export DEBIAN_FRONTEND=noninteractive
  MIN_MODE=${MIN_MODE}

  apt-get update

  if \$MIN_MODE; then
    apt-get install -y --no-install-recommends \
      openssh-server sudo curl git tmux vim-tiny \
      jq ripgrep fd-find htop wget unzip ca-certificates \
      systemd
  else
    apt-get install -y \
      openssh-server sudo curl git tmux vim \
      build-essential \
      jq ripgrep fd-find htop wget unzip ca-certificates \
      systemd
  fi

  # Prefer IPv4 to avoid slow/broken IPv6 connections
  sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

  # Install Docker CE
  curl -fsSL https://get.docker.com | sh

  # Install Mise
  curl https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

  # Tailscale
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable tailscaled

  # Claude Code
  curl -fsSL https://claude.ai/install.sh | BIN_DIR=/usr/local/bin bash

  # SSH configuration (key-only auth)
  mkdir -p /var/run/sshd
  sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

  # Enable Docker and SSH as systemd services
  systemctl enable docker
  systemctl enable ssh

  # Clean up
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

  if \$MIN_MODE; then
    # Aggressive cleanup for minimal image
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
    rm -rf /usr/share/locale/* /usr/share/i18n/*
    rm -rf /var/log/*.log /var/log/**/*.log
    # Remove Docker buildx plugin (compose is kept)
    rm -f /usr/libexec/docker/cli-plugins/docker-buildx
  fi
"

# Push tmux config
echo "Pushing tmux.conf..."
incus file push "$SCRIPT_DIR/tmux.conf" "$BUILD_INSTANCE/etc/tmux.conf"

echo "Stopping build instance..."
incus stop "$BUILD_INSTANCE"

# Delete old image alias if it exists
if incus image alias list --format csv | grep -q "^${IMAGE_ALIAS},"; then
  echo "Removing old image alias..."
  old_fingerprint=$(incus image alias list --format csv | grep "^${IMAGE_ALIAS}," | cut -d',' -f2)
  incus image alias delete "$IMAGE_ALIAS"
  incus image delete "$old_fingerprint" 2>/dev/null || true
fi

echo "Publishing image as ${IMAGE_ALIAS}..."
incus publish "$BUILD_INSTANCE" --alias "$IMAGE_ALIAS" \
  --compression zstd

echo "Cleaning up build instance..."
incus delete "$BUILD_INSTANCE"

echo ""
echo "=== Image built successfully ==="
echo "Verify with: incus image list ${IMAGE_ALIAS}"
