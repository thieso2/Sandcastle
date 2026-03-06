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
    mkdir -p "$SSH_DIR" 2>/dev/null || true
    if [ -d "$SSH_DIR" ]; then
        if [ -f "$SSH_DIR/authorized_keys" ]; then
            grep -qF "$SSH_KEY" "$SSH_DIR/authorized_keys" || echo "$SSH_KEY" >> "$SSH_DIR/authorized_keys"
        else
            echo "$SSH_KEY" > "$SSH_DIR/authorized_keys"
        fi
        chmod 700 "$SSH_DIR" 2>/dev/null || true
        chmod 600 "$SSH_DIR/authorized_keys" 2>/dev/null || true
    fi
fi

# Set correct ownership and permissions on the home directory.
# chown -R covers .ssh, .local, and anything else created above.
#
# NOTE: when the home dir is bind-mounted, it may be owned by a host UID that
# falls outside this Sysbox container's user-namespace mapping (e.g. host
# root, UID 0).  That host UID appears as nobody (65534) inside the container,
# so chown fails silently for the directory itself.  We keep the dir world-
# writable (777) so the sandbox user can still write ~/.Xauthority (VNC) and
# other home-dir files even when they don't own the directory.  sshd is
# configured with StrictModes no to accept this arrangement.
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" 2>/dev/null || true
chmod 777 "/home/$USERNAME"

# Ensure workspace is accessible
chown "$USERNAME:$USERNAME" /workspace 2>/dev/null || true

# Configure git identity in user's ~/.gitconfig (skip if it already exists,
# e.g. from a bind-mounted home directory with prior customizations)
GITCONFIG="/home/$USERNAME/.gitconfig"
if [ ! -f "$GITCONFIG" ] && { [ -n "$USER_FULLNAME" ] || [ -n "$USER_EMAIL" ]; }; then
    {
        echo "[user]"
        [ -n "$USER_FULLNAME" ] && echo "        name = $USER_FULLNAME"
        [ -n "$USER_EMAIL" ] && echo "        email = $USER_EMAIL"
        [ -n "$GITHUB_USERNAME" ] && echo "[github]" && echo "        user = $GITHUB_USERNAME"
    } > "$GITCONFIG"
    chown "$USERNAME:$USERNAME" "$GITCONFIG" 2>/dev/null || true
fi

# Generate SSH host keys if missing
ssh-keygen -A

# Resize /dev/shm to 2GB for Chrome. Docker's ShmSize HostConfig key is not
# supported by sysbox-runc, so we do it here instead. The runtime bind-mounts
# /dev/shm from a small constrained shm, so "remount,size=" fails; unmounting
# it and mounting a fresh tmpfs works.
umount /dev/shm 2>/dev/null || true
mount -t tmpfs -o size=2g,mode=1777 tmpfs /dev/shm 2>/dev/null || true

# Start Docker daemon with self-healing startup.
# Runs a background watcher so sshd is not delayed.
# Handles known sysbox/kernel incompatibilities automatically:
#   - Wrong /var/lib/docker ownership (sysbox on kernel 6.17+)
#   - /dev/fuse absent (not needed — overlay2 works via sysbox kernel virtualisation)
# Status is written to /run/docker-status and shown on every SSH login.
if command -v dockerd &>/dev/null; then
    (
        MTU=$(ip link show eth0 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 1500)

        _wait_for_socket() {
            for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                sleep 1
                [ -S /var/run/docker.sock ] && return 0
            done
            return 1
        }

        _attempt_start() {
            # /var/lib/docker is a sysbox-managed BTRFS bind-mount. Dockyard's
            # DinD ownership watcher (dockyard.sh) chowns its backing dir to the
            # sysbox uid offset within ~1 s of container creation, making it
            # accessible to container root. Docker 29+ requires chmod on the
            # data-root; that succeeds once the backing dir is correctly owned.
            dockerd --storage-driver=overlay2 --mtu="$MTU" &>/var/log/dockerd.log &
            _wait_for_socket
        }

        if _attempt_start; then
            echo "ready" > /run/docker-status
        else
            # First attempt failed (likely backing dir not yet chowned by watcher).
            # Wait a few more seconds and retry — the watcher runs every ~1 s.
            pkill -x dockerd 2>/dev/null || true
            sleep 5
            if _attempt_start; then
                echo "ready (recovered)" > /run/docker-status
            else
                echo "FAILED — run 'docker-restart' or check /var/log/dockerd.log" > /run/docker-status
            fi
        fi
    ) &
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
    # Start websockify-go: proxies WebSocket connections to Xvnc on port 6080.
    # noVNC static files are served from the Rails app (public/novnc/), not here.
    touch /var/log/websockify.log
    chown "$USERNAME:$USERNAME" /var/log/websockify.log
    websockify -addr :6080 -target localhost:5900 -url /websockify &>/var/log/websockify.log &
    # Export DISPLAY for all SSH sessions via PAM environment
    echo "DISPLAY=:99" >> /etc/environment
fi

# Start ttyd web terminals (run as sandbox user)
# Port 7681: tmux session (persistent, re-attaches; unlimited clients)
# Port 7682: plain login shell (one client at a time)
if command -v ttyd &>/dev/null; then
    touch /var/log/ttyd-tmux.log /var/log/ttyd-shell.log
    chown "$USERNAME:$USERNAME" /var/log/ttyd-tmux.log /var/log/ttyd-shell.log
    su -s /bin/bash "$USERNAME" -c \
        "ttyd -W -m 0 -p 7681 tmux new-session -A -s main &>/var/log/ttyd-tmux.log &"
    su -s /bin/bash "$USERNAME" -c \
        "ttyd -W -m 1 -p 7682 bash -l &>/var/log/ttyd-shell.log &"
fi

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
