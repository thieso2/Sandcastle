#!/bin/bash
# Build the sandcastle-tailscale Incus image (Ubuntu 24.04 + Tailscale).
# Run on the Incus host: bash images/tailscale/build-image.sh
set -euo pipefail

IMAGE_ALIAS="sandcastle-tailscale"
BUILD_INSTANCE="build-tailscale-image"

echo "=== Building Sandcastle Tailscale sidecar image ==="

# Clean up any previous build instance
if incus info "$BUILD_INSTANCE" &>/dev/null; then
  echo "Cleaning up previous build instance..."
  incus stop "$BUILD_INSTANCE" --force 2>/dev/null || true
  incus delete "$BUILD_INSTANCE" --force
fi

# Launch a fresh Ubuntu 24.04 container
echo "Launching build instance..."
incus launch images:ubuntu/24.04/cloud "$BUILD_INSTANCE"

echo "Waiting for instance to be ready..."
sleep 5
incus exec "$BUILD_INSTANCE" -- cloud-init status --wait 2>/dev/null || sleep 10

echo "Installing Tailscale..."
incus exec "$BUILD_INSTANCE" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y curl ca-certificates iptables iproute2

  # Install Tailscale
  curl -fsSL https://tailscale.com/install.sh | sh

  # Enable tailscaled service
  systemctl enable tailscaled

  # Clean up
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
'

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
echo "=== Tailscale image built successfully ==="
echo "Verify with: incus image list ${IMAGE_ALIAS}"
