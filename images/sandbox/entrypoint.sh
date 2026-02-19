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

# Resize /dev/shm to 2GB for Chrome. Docker's ShmSize HostConfig key is not
# supported by sysbox-runc, so we do it here instead. The runtime bind-mounts
# /dev/shm from a small constrained shm, so "remount,size=" fails; unmounting
# it and mounting a fresh tmpfs works.
umount /dev/shm 2>/dev/null || true
mount -t tmpfs -o size=2g,mode=1777 tmpfs /dev/shm 2>/dev/null || true

# Start Docker daemon in background (requires Sysbox runtime for isolated /var/lib/docker)
# Don't wait for it to be ready - users can check with `docker info` after SSH login
if command -v dockerd &>/dev/null && [ -e /dev/fuse ]; then
    # Match inner Docker bridge MTU to container's eth0 to avoid packet fragmentation
    ETH0_MTU=$(ip link show eth0 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 1500)
    dockerd --storage-driver=overlay2 --mtu="$ETH0_MTU" &>/var/log/dockerd.log &
else
    echo "Note: Docker-in-Docker not available (requires sysbox-runc runtime)" >&2
fi

# Start virtual X + VNC server for browser access.
# Xvnc (TigerVNC) combines Xvfb and a VNC server in a single process and sends
# the RFB banner immediately on connect — required for websockify compatibility.
# x11vnc 0.9.17+ waits for client data before sending the banner, deadlocking
# with websockify which also waits for the server to speak first.
# Both processes run as $USERNAME (not root) for proper display ownership.
VNC_ENABLED="${SANDCASTLE_VNC_ENABLED:-1}"
VNC_GEOMETRY="${SANDCASTLE_VNC_GEOMETRY:-1280x900}"
VNC_DEPTH="${SANDCASTLE_VNC_DEPTH:-24}"

if command -v Xvnc &>/dev/null && [ "$VNC_ENABLED" = "1" ]; then
    touch /var/log/xvnc.log /var/log/openbox.log
    chown "$USERNAME:$USERNAME" /var/log/xvnc.log /var/log/openbox.log
    su -s /bin/bash "$USERNAME" -c \
        "Xvnc :99 -rfbport 5900 -SecurityTypes None -AlwaysShared -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} &>/var/log/xvnc.log &"
    # Start Openbox window manager once the display is ready
    if command -v openbox &>/dev/null; then
        su -s /bin/bash "$USERNAME" -c \
            'DISPLAY=:99 openbox &>/var/log/openbox.log &'
    fi
fi

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
