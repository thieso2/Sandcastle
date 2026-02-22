#!/bin/bash
set -e

USERNAME="${SANDCASTLE_USER:-sandbox}"
SSH_KEY="${SANDCASTLE_SSH_KEY:-}"

# Create user if not exists
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/sandcastle
    chmod 0440 /etc/sudoers.d/sandcastle
fi

# Append SSH key (don't overwrite — multiple sandboxes may share home dir)
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
fi

# Ownership and permissions required by sshd StrictModes
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" 2>/dev/null || true
chmod 755 "/home/$USERNAME"

# Generate SSH host keys if missing
ssh-keygen -A

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
