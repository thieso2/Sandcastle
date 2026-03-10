#!/bin/bash
# Wrapper for tmux that preserves SSH agent forwarding across sessions.
#
# Two complementary mechanisms:
# 1. Symlink: ~/.ssh/agent_sock → current forwarded socket (immediate, always works)
# 2. ssh-agent-switcher daemon: proxies agent requests to the most recent
#    valid forwarded socket (handles reattach from new SSH connections)

SAS_PID="$HOME/.local/state/ssh-agent-switcher.pid"
SAS_SOCK="/tmp/ssh-agent.$USER"

# Save the current forwarded agent socket as a stable symlink
if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    mkdir -p ~/.ssh 2>/dev/null
    ln -sf "$SSH_AUTH_SOCK" ~/.ssh/agent_sock
fi

# Start or restart ssh-agent-switcher daemon (creates /tmp/ssh-agent.$USER).
# Always restart — the old daemon holds a reference to a dead forwarded socket.
if command -v ssh-agent-switcher >/dev/null 2>&1; then
    # Kill existing daemon via PID file
    if [ -f "$SAS_PID" ]; then
        kill "$(cat "$SAS_PID")" 2>/dev/null
        sleep 0.3
    fi
    rm -f "$SAS_SOCK" "$SAS_PID" 2>/dev/null

    ssh-agent-switcher --daemon 2>/dev/null
    # Wait for daemon socket to appear
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "$SAS_SOCK" ] && break
        sleep 0.3
    done
    # Poke daemon to discover the current forwarded socket
    SSH_AUTH_SOCK="$SAS_SOCK" ssh-add -l >/dev/null 2>&1 || true
fi

cd ~ 2>/dev/null
exec tmux new-session -A -s main
