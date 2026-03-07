#!/bin/bash
# Wrapper for tmux that preserves SSH agent forwarding across sessions.
#
# When SSH connects with -A, sshd creates a temporary agent socket.
# We symlink a stable path to it so tmux sessions always find the
# latest forwarded agent — even on reattach.

if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    mkdir -p ~/.ssh 2>/dev/null
    ln -sf "$SSH_AUTH_SOCK" ~/.ssh/agent_sock
    export SSH_AUTH_SOCK=~/.ssh/agent_sock
fi

exec tmux new-session -A -s main
