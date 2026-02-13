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

# Set up SSH authorized keys (append if not already present, preserving
# any WeTTY keys that may have been injected for other sandboxes sharing
# this user's home directory via bind mount).
if [ -n "$SSH_KEY" ]; then
    SSH_DIR="/home/$USERNAME/.ssh"
    mkdir -p "$SSH_DIR"
    if [ -f "$SSH_DIR/authorized_keys" ]; then
        grep -qF "$SSH_KEY" "$SSH_DIR/authorized_keys" || echo "$SSH_KEY" >> "$SSH_DIR/authorized_keys"
    else
        echo "$SSH_KEY" > "$SSH_DIR/authorized_keys"
    fi
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
fi

# Ensure home directory ownership and permissions.
# The host may create bind-mounted home dirs with 777 so Sysbox-mapped root
# can write. Tighten to 755 here so sshd StrictModes is satisfied.
chown "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 755 "/home/$USERNAME"

# Ensure workspace is accessible
chown "$USERNAME:$USERNAME" /workspace 2>/dev/null || true

# Seed mise + Claude Code into user's ~/.local/bin on first boot
USER_LOCAL_BIN="/home/$USERNAME/.local/bin"
mkdir -p "$USER_LOCAL_BIN"
for tool in mise claude; do
    if [ ! -f "$USER_LOCAL_BIN/$tool" ] && [ -f "/opt/sandcastle/bin/$tool" ]; then
        cp "/opt/sandcastle/bin/$tool" "$USER_LOCAL_BIN/$tool"
    fi
done
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.local"

# Configure git identity system-wide if provided
if [ -n "$USER_FULLNAME" ] || [ -n "$USER_EMAIL" ]; then
    {
        echo "[user]"
        [ -n "$USER_FULLNAME" ] && echo "    name = $USER_FULLNAME"
        [ -n "$USER_EMAIL" ] && echo "    email = $USER_EMAIL"
    } >> /etc/gitconfig
fi

# Generate SSH host keys if missing
ssh-keygen -A

# Start Docker daemon in background (requires Sysbox runtime for isolated /var/lib/docker)
if command -v dockerd &>/dev/null && [ -e /dev/fuse ]; then
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
else
    echo "Note: Docker-in-Docker not available (requires sysbox-runc runtime)" >&2
fi

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
