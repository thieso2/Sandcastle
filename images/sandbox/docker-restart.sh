#!/bin/bash
# docker-restart: manually recover the Docker-in-Docker daemon inside this sandbox.
#
# Usage:
#   docker-restart          — stop, fix ownership, restart dockerd
#   docker-restart --reset  — also wipe /var/lib/docker
#                             WARNING: destroys all inner images and containers

set -euo pipefail

RESET=0
[ "${1:-}" = "--reset" ] && RESET=1

echo "Stopping existing dockerd..."
sudo pkill -x dockerd 2>/dev/null || true
sleep 2

if [ "$RESET" = "1" ]; then
    echo "WARNING: Wiping /var/lib/docker — all inner images and containers will be lost."
    sudo rm -rf /var/lib/docker
fi

sudo mkdir -p /var/lib/docker
sudo chown root:root /var/lib/docker

MTU=$(ip link show eth0 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 1500)
echo "Starting dockerd (MTU=${MTU})..."
sudo dockerd --storage-driver=overlay2 --mtu="$MTU" &>/var/log/dockerd.log &

echo -n "Waiting for Docker socket"
for _i in $(seq 20); do
    echo -n "."
    sleep 1
    if [ -S /var/run/docker.sock ]; then
        echo
        echo "Docker is ready!"
        echo "ready (manual restart)" | sudo tee /run/docker-status >/dev/null
        exit 0
    fi
done

echo
echo "ERROR: dockerd did not start within 20 seconds."
echo "Check /var/log/dockerd.log for details."
echo "If the problem persists, try: docker-restart --reset"
exit 1
