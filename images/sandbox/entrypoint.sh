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
# SSH_KEY may contain multiple keys separated by newlines.
if [ -n "$SSH_KEY" ]; then
    SSH_DIR="/home/$USERNAME/.ssh"
    mkdir -p "$SSH_DIR" 2>/dev/null || true
    if [ -d "$SSH_DIR" ]; then
        touch "$SSH_DIR/authorized_keys"
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            grep -qF "$key" "$SSH_DIR/authorized_keys" || echo "$key" >> "$SSH_DIR/authorized_keys"
        done <<< "$SSH_KEY"
        chmod 700 "$SSH_DIR" 2>/dev/null || true
        chmod 600 "$SSH_DIR/authorized_keys" 2>/dev/null || true
    fi
fi

# Set correct ownership and permissions on the home directory.
# chown -R covers .ssh, .local, and anything else created above.
# The host ensures 777 on the mount point before container start (via sudo
# chmod in SandboxManager#prepare_bind_mount), so the sandbox user can always
# write ~/.Xauthority, .ssh, etc.
#
# On BTRFS bind mounts with Sysbox ID-mapped mounts, chmod/chown may fail
# with EOVERFLOW ("Value too large for defined data type"). This is a known
# Sysbox bug (thieso2/sysbox#12). Log the error visibly but don't crash —
# the host has already set 777 on the mount point.
if ! chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" 2>/tmp/chown-home.err; then
    echo "WARNING: chown /home/$USERNAME failed: $(cat /tmp/chown-home.err | head -1)" >&2
    echo "  This is likely BTRFS + Sysbox ID-mapped mount issue (thieso2/sysbox#12)" >&2
fi
if ! chmod 777 "/home/$USERNAME" 2>/tmp/chmod-home.err; then
    echo "WARNING: chmod /home/$USERNAME failed: $(cat /tmp/chmod-home.err | head -1)" >&2
    echo "  This is likely BTRFS + Sysbox ID-mapped mount issue (thieso2/sysbox#12)" >&2
fi

# Fix ownership on persisted data volume. Multiple sandboxes can share the
# same user's data path, each with a different Sysbox UID mapping. Run in
# background to avoid delaying SSH readiness.
if [ -d /persisted ]; then
    (chown -R "$USERNAME:$USERNAME" /persisted 2>/dev/null || true) &
fi

# Seed Claude Code into the user's $HOME if not already present. The base
# image ships the binary at /opt/claude/claude (off $PATH); each user gets
# their own copy at ~/.local/bin/claude. Because $HOME is bind-mounted from
# the host, `claude --update` persists across sandbox recreations and
# survives base-image rebuilds. To pick up a newer base-image version, the
# user deletes ~/.local/bin/claude and restarts the sandbox.
CLAUDE_SRC="/opt/claude/claude"
CLAUDE_DST="/home/$USERNAME/.local/bin/claude"
if [ -x "$CLAUDE_SRC" ] && [ ! -e "$CLAUDE_DST" ]; then
    install -d -o "$USERNAME" -g "$USERNAME" -m 0755 "/home/$USERNAME/.local/bin" 2>/dev/null || true
    install -o "$USERNAME" -g "$USERNAME" -m 0755 "$CLAUDE_SRC" "$CLAUDE_DST" 2>/dev/null || \
        echo "WARNING: could not seed $CLAUDE_DST from $CLAUDE_SRC" >&2
fi

# Configure git identity in user's ~/.gitconfig (skip if it already exists,
# e.g. from a bind-mounted home directory with prior customizations)
GITCONFIG="/home/$USERNAME/.gitconfig"
if [ ! -f "$GITCONFIG" ] && { [ -n "$USER_FULLNAME" ] || [ -n "$USER_EMAIL" ]; }; then
    if ! {
        echo "[user]"
        [ -n "$USER_FULLNAME" ] && echo "        name = $USER_FULLNAME"
        [ -n "$USER_EMAIL" ] && echo "        email = $USER_EMAIL"
        [ -n "$GITHUB_USERNAME" ] && echo "[github]" && echo "        user = $GITHUB_USERNAME"
    } > "$GITCONFIG" 2>/dev/null; then
        echo "WARNING: could not write $GITCONFIG (home dir may be read-only under Sysbox)" >&2
    else
        chown "$USERNAME:$USERNAME" "$GITCONFIG" 2>/dev/null || true
    fi
fi

# Sandcastle metadata directory — used for baseline snapshot of $HOME
# (read by the web app's "discover new files" feature) and any future
# per-container state we want isolated from the user's home dir.
mkdir -p /var/sandcastle
chmod 755 /var/sandcastle

# Manage the tmux auto-attach block in ~/.bashrc. Runs every container
# start so toggling the setting applies on next sandbox launch. Uses
# fenced markers so we can reliably replace/remove just our block without
# disturbing user edits elsewhere in .bashrc.
BASHRC="/home/$USERNAME/.bashrc"
BEGIN_MARK="# >>> sandcastle ssh tmux auto-attach >>>"
END_MARK="# <<< sandcastle ssh tmux auto-attach <<<"
if [ -f "$BASHRC" ] || [ -f /etc/skel/.bashrc ]; then
    [ -f "$BASHRC" ] || cp /etc/skel/.bashrc "$BASHRC" 2>/dev/null || touch "$BASHRC"
    # Strip any previous block.
    sed -i "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" "$BASHRC" 2>/dev/null || true
    if [ "${SANDCASTLE_SSH_START_TMUX:-1}" = "1" ]; then
        cat >> "$BASHRC" <<'TMUX_EOF'
# >>> sandcastle ssh tmux auto-attach >>>
# Auto-attach to a shared tmux session for interactive SSH logins.
# Toggle via the sandbox's "Start tmux on SSH" setting.
if [ -z "$TMUX" ] && [ -n "$SSH_CONNECTION" ] && [[ $- == *i* ]] && command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s main
fi
# <<< sandcastle ssh tmux auto-attach <<<
TMUX_EOF
    fi
    chown "$USERNAME:$USERNAME" "$BASHRC" 2>/dev/null || true
fi

# Generate SSH host keys if missing
ssh-keygen -A

# Generate login banner with sandbox configuration
# Resolve values at container start, bake them into the profile script.
_SC_VERSION="unknown"
[ -f /etc/sandcastle-version ] && _SC_VERSION=$(cat /etc/sandcastle-version)
_SC_HOME="ephemeral"
[ "${SANDCASTLE_HOME_PERSISTED:-0}" = "1" ] && _SC_HOME="persisted"
_SC_DATA="none"
if [ "${SANDCASTLE_DATA_PERSISTED:-0}" = "1" ]; then
    _SC_DP="${SANDCASTLE_DATA_PATH:-.}"
    _SC_DATA="persisted (/persisted)"
    [ "$_SC_DP" != "." ] && _SC_DATA="persisted (/persisted — $_SC_DP)"
fi
_SC_VNC="enabled";  [ "${SANDCASTLE_VNC_ENABLED:-1}" = "0" ]    && _SC_VNC="disabled"
_SC_DKR="enabled";  [ "${SANDCASTLE_DOCKER_ENABLED:-1}" = "0" ] && _SC_DKR="disabled"

cat > /etc/profile.d/sandcastle-banner.sh <<BANNER_EOF
#!/bin/bash
[[ \$- == *i* ]] || return 0
[[ -n "\${SANDCASTLE_BANNER_SHOWN:-}" ]] && return 0
export SANDCASTLE_BANNER_SHOWN=1

cat << 'ART'

  ███████╗ █████╗ ███╗   ██╗██████╗  ██████╗ █████╗ ███████╗████████╗██╗     ███████╗
  ██╔════╝██╔══██╗████╗  ██║██╔══██╗██╔════╝██╔══██╗██╔════╝╚══██╔══╝██║     ██╔════╝
  ███████╗███████║██╔██╗ ██║██║  ██║██║     ███████║███████╗   ██║   ██║     █████╗
  ╚════██║██╔══██║██║╚██╗██║██║  ██║██║     ██╔══██║╚════██║   ██║   ██║     ██╔══╝
  ███████║██║  ██║██║ ╚████║██████╔╝╚██████╗██║  ██║███████║   ██║   ███████╗███████╗
  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚══════╝

ART
echo "  Version:  $_SC_VERSION"
echo "  Home:     $_SC_HOME"
echo "  Data:     $_SC_DATA"
echo "  VNC:      $_SC_VNC"
echo "  Docker:   $_SC_DKR"
echo ""
BANNER_EOF
chmod +x /etc/profile.d/sandcastle-banner.sh

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
# Status is written to /run/docker-status.
DOCKER_ENABLED="${SANDCASTLE_DOCKER_ENABLED:-1}"
if command -v dockerd &>/dev/null && [ "$DOCKER_ENABLED" = "1" ]; then
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
            #
            # --userland-proxy=false: use hairpin NAT via iptables instead of
            # spawning a docker-proxy process per published port per address
            # family. Each proxy is ~5 MB RSS; a nested sandbox that publishes
            # a large port range (e.g. -p 3000-5000) otherwise accumulates
            # hundreds of docker-proxy processes and ~1 GB of RSS overhead.
            dockerd --storage-driver=overlay2 --mtu="$MTU" --userland-proxy=false &>/var/log/dockerd.log &
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

# Set up and start Samba for SMB file sharing (SMB3-only, no NetBIOS).
# Accessible via the sandbox's Tailscale IP on port 445: smb://<ip>/home or smb://<ip>/persisted
SMB_ENABLED="${SANDCASTLE_SMB_ENABLED:-0}"
if command -v smbd &>/dev/null && [ "$SMB_ENABLED" = "1" ]; then
    cat > /etc/samba/smb.conf << SMBCONF
[global]
    disable netbios = yes
    smb ports = 445
    server min protocol = SMB3
    server max protocol = SMB3_11
    smb encrypt = if_required
    server signing = required
    map to guest = never
    restrict anonymous = 2
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
    log level = 1
    log file = /var/log/samba/smbd.log
    wide links = yes
    allow insecure wide links = yes
    vfs objects = fruit streams_depot
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = yes
    fruit:nfs_aces = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes
    oplocks = no
    level2 oplocks = no

[home]
    path = /home/$USERNAME
    browseable = yes
    read only = no
    valid users = $USERNAME
    guest ok = no
    create mask = 0644
    directory mask = 0755
SMBCONF

    # Add persisted data share if the volume is mounted
    if [ -d /persisted ]; then
        cat >> /etc/samba/smb.conf << SMBCONF2

[persisted]
    path = /persisted
    browseable = yes
    read only = no
    valid users = $USERNAME
    guest ok = no
    create mask = 0644
    directory mask = 0755
SMBCONF2
    fi

    mkdir -p /var/log/samba /run/samba
    # SMB password is injected post-start via docker exec (not via env var)
    touch /var/log/samba/smbd.log
    smbd --foreground --no-process-group &>/var/log/samba/smbd.log &
fi

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
