# Build websockify-go: minimal WebSocket→TCP proxy (~5 MB static binary)
FROM golang:1.26-alpine AS websockify-builder
WORKDIR /build
COPY websockify/ .
# go mod tidy downloads deps and generates go.sum; -mod=mod allows updating go.sum at build time
RUN go mod tidy && CGO_ENABLED=0 go build -ldflags="-s -w" -o websockify .

FROM ubuntu:25.10

ARG SANDCASTLE_VERSION=dev

ENV DEBIAN_FRONTEND=noninteractive

# System tools
RUN apt-get update && apt-get install -y \
    openssh-server sudo curl git tmux vim neovim \
    build-essential \
    jq ripgrep fd-find htop wget unzip ca-certificates net-tools iproute2 iputils-ping \
    mosh \
    && rm -rf /var/lib/apt/lists/*

# GUI tools: TigerVNC (Xvnc = virtual X server + VNC server combined) and window manager.
# Xvnc sends the RFB banner immediately on connect, unlike x11vnc 0.9.17+ which waits
# for client data first (breaking websockify's server-speaks-first expectation).
# noVNC static files are served from the Rails app (public/novnc/), not from the sandbox.
RUN apt-get update && apt-get install -y \
    tigervnc-standalone-server openbox xterm xfonts-base xfonts-100dpi xfonts-75dpi \
    && rm -rf /var/lib/apt/lists/*

# websockify-go: single static binary replaces python3-websockify (~50 MB → ~5 MB)
COPY --from=websockify-builder /build/websockify /usr/local/bin/websockify

# Google Chrome (amd64) or Chromium (arm64) — Google doesn't ship a Chrome deb for arm64
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "amd64" ]; then \
      apt-get update \
      && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
      && apt-get install -y ./google-chrome-stable_current_amd64.deb \
      && rm google-chrome-stable_current_amd64.deb \
      && rm -rf /var/lib/apt/lists/*; \
    else \
      # Ubuntu ships chromium as a snap-only wrapper since 19.10 — unusable in containers.
      # Pull the real chromium .deb from Debian testing (arm64 only), pinned so nothing
      # else is silently upgraded from Debian.
      apt-get update && apt-get install -y --no-install-recommends curl gpg \
      && curl -fsSL https://ftp-master.debian.org/keys/archive-key-12.asc \
           | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-archive.gpg \
      && echo "deb [arch=arm64] http://deb.debian.org/debian testing main" \
           > /etc/apt/sources.list.d/debian-testing.list \
      && printf 'Package: *\nPin: release o=Debian\nPin-Priority: 100\n\nPackage: chromium chromium-common chromium-sandbox\nPin: release o=Debian\nPin-Priority: 500\n' \
           > /etc/apt/preferences.d/debian-chromium \
      && apt-get update \
      && apt-get install -y chromium \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Prefer IPv4 to avoid slow/broken IPv6 connections
RUN sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Docker CLI + daemon (Sysbox makes this safe)
# Use manual apt repo instead of get.docker.com convenience script —
# that script tries to install ca-certificates/curl which Ubuntu 25.10 already
# has at newer versions, causing "E: Packages were downgraded".
# Pin to 'noble' — Docker has no packages for Ubuntu 25.10 (questing) yet.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y \
         docker-ce=5:29.0.3-1~ubuntu.24.04~noble \
         docker-ce-cli=5:29.0.3-1~ubuntu.24.04~noble \
         containerd.io=1.7.27-1 \
         docker-buildx-plugin=0.24.0-1~ubuntu.24.04~noble \
         docker-compose-plugin=2.40.3-1~ubuntu.24.04~noble \
    && rm -rf /var/lib/apt/lists/*

# Pin runc — multiple runc versions break inside sysbox containers:
#   runc 1.2+  — /proc/thread-self handling change (fixed in sysbox 0.6.6)
#   runc 1.3.3 — CVE-2025-52881 fix detects sysbox's virtual /proc as an
#                unsafe cross-device mount and aborts ALL container init
#                (nestybox/sysbox#973, unresolved as of Feb 2026)
# Also: containerd.io ≥ 2.x breaks sysbox-runc entirely (nestybox/sysbox#958).
# Pinned above to containerd.io=1.7.27-1 (last safe version before both
# the 1.7.28-2 behavioural change and the 2.x series). See Sandcastle issue #56.
# containerd calls /usr/bin/runc — overwriting it here pins it regardless of
# which docker-ce or containerd.io version is installed above.
RUN RUNC_VERSION="v1.1.15" \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" \
       -o /usr/bin/runc \
    && chmod +x /usr/bin/runc

# Stage mise + Claude Code in /opt/sandcastle/bin (seeded to ~/.local/bin on first boot)
RUN mkdir -p /opt/sandcastle/bin \
    && curl https://mise.run | MISE_INSTALL_PATH=/opt/sandcastle/bin/mise sh \
    && curl -fsSL https://claude.ai/install.sh | bash \
    && cp -L /root/.local/bin/claude /opt/sandcastle/bin/claude \
    && rm -rf /root/.local/share/claude /root/.local/bin/claude

# ttyd — web terminal (two ports: 7681=tmux, 7682=shell)
RUN ARCH=$(dpkg --print-architecture) \
    && TTYD_ARCH=$([ "$ARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${TTYD_ARCH}" \
       -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# Entire CLI — git observability for AI agent sessions (https://entire.io)
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/entireio/cli/releases/latest/download/entire_linux_${ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin entire \
    && chmod +x /usr/local/bin/entire

# Shell config: PATH, mise activation, aliases
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/bash.bashrc \
    && echo 'eval "$(mise activate bash)"' >> /etc/bash.bashrc \
    && echo "alias yolo='claude --dangerously-skip-permissions'" >> /etc/bash.bashrc \
    && echo '[ -r /run/docker-status ] && echo "DinD: $(cat /run/docker-status)"' >> /etc/bash.bashrc

# Bake version into the image
RUN echo "${SANDCASTLE_VERSION}" > /etc/sandcastle-version

# SSH configuration (key-only auth) — use drop-in config for Ubuntu 25.10 compatibility
RUN mkdir -p /var/run/sshd /etc/ssh/sshd_config.d \
    && echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/10-sandcastle.conf \
    && echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/10-sandcastle.conf \
    && echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/10-sandcastle.conf

COPY entrypoint.sh /entrypoint.sh
COPY docker-restart.sh /usr/local/bin/docker-restart
RUN chmod +x /entrypoint.sh /usr/local/bin/docker-restart

COPY startchrome.sh /usr/local/bin/google-chrome
RUN chmod +x /usr/local/bin/google-chrome \
    && ln -s /usr/local/bin/google-chrome /usr/local/bin/startchrome

COPY tmux.conf /etc/tmux.conf
COPY gitconfig /etc/gitconfig

LABEL org.opencontainers.image.source="https://github.com/thieso2/sandcastle"
LABEL org.opencontainers.image.description="Sandcastle sandbox image — Ubuntu 25.10 with Docker-in-Docker, SSH, and dev tools"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /workspace
EXPOSE 22 5900 6080 7681 7682
EXPOSE 60000-61000/udp

ENTRYPOINT ["/entrypoint.sh"]
