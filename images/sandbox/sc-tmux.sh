#!/bin/bash
# Wrapper for tmux that preserves SSH agent forwarding across sessions.
#
# ssh-agent-switcher daemon scans /tmp for forwarded agent sockets and
# proxies them through a stable socket at /tmp/ssh-agent.$USER. We
# trigger a scan (ssh-add -l) so the daemon picks up the new forwarded
# socket BEFORE tmux starts — otherwise the first ssh-add in the
# session hits the daemon before it has connected.

if command -v ssh-agent-switcher >/dev/null 2>&1; then
    # Ensure daemon is running
    ssh-agent-switcher --daemon 2>/dev/null

    # Trigger daemon to discover the new forwarded socket by querying it
    SSH_AUTH_SOCK="/tmp/ssh-agent.$USER" ssh-add -l >/dev/null 2>&1 || true
fi

exec tmux new-session -A -s main
