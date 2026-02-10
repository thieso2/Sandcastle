#!/bin/bash
set -e

USERNAME="${SANDCASTLE_USER:-sandbox}"
SSH_KEY="${SANDCASTLE_SSH_KEY:-}"

# Create user if not exists
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,docker "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/sandcastle
    chmod 0440 /etc/sudoers.d/sandcastle
fi

# Set up SSH authorized keys
if [ -n "$SSH_KEY" ]; then
    SSH_DIR="/home/$USERNAME/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$SSH_KEY" > "$SSH_DIR/authorized_keys"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
fi

# Ensure home directory ownership
chown "$USERNAME:$USERNAME" "/home/$USERNAME"

# Ensure workspace is accessible
chown "$USERNAME:$USERNAME" /workspace 2>/dev/null || true

# Generate SSH host keys if missing
ssh-keygen -A

# Start Docker daemon in background (Sysbox provides isolated /var/lib/docker)
if command -v dockerd &>/dev/null; then
    # Match inner Docker bridge MTU to container's eth0 to avoid packet fragmentation
    ETH0_MTU=$(ip link show eth0 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 1500)
    dockerd --storage-driver=overlay2 --mtu="$ETH0_MTU" &>/var/log/dockerd.log &
    # Wait briefly for Docker daemon to be ready
    for i in $(seq 1 30); do
        if docker info &>/dev/null; then
            break
        fi
        sleep 1
    done
fi

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
