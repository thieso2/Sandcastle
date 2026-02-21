FROM ubuntu:25.10

ARG SANDCASTLE_VERSION=dev

ENV DEBIAN_FRONTEND=noninteractive

# System tools
RUN apt-get update && apt-get install -y \
    openssh-server sudo curl git tmux vim neovim \
    build-essential \
    jq ripgrep fd-find htop wget unzip ca-certificates net-tools iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# GUI tools: TigerVNC (Xvnc = virtual X server + VNC server combined), noVNC static
# files, websockify (WebSocket→RFB proxy), and window manager.
# Xvnc sends the RFB banner immediately on connect, unlike x11vnc 0.9.17+ which waits
# for client data first (breaking websockify's server-speaks-first expectation).
RUN apt-get update && apt-get install -y \
    tigervnc-standalone-server openbox xterm xfonts-base xfonts-100dpi xfonts-75dpi \
    novnc python3-websockify \
    && rm -rf /var/lib/apt/lists/*

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
    && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Pin runc to 1.1.x — runc 1.2+ added a procfs safety check that fails
# inside sysbox containers (sysbox-fs mounts /proc/sys as separate FUSE)
RUN RUNC_VERSION="v1.1.15" \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" \
       -o /usr/bin/runc \
    && chmod +x /usr/bin/runc

# Docker Compose plugin
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
       -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

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
    && echo "alias yolo='claude --dangerously-skip-permissions'" >> /etc/bash.bashrc

# Bake version into the image
RUN echo "${SANDCASTLE_VERSION}" > /etc/sandcastle-version

# SSH configuration (key-only auth) — use drop-in config for Ubuntu 25.10 compatibility
RUN mkdir -p /var/run/sshd /etc/ssh/sshd_config.d \
    && echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/10-sandcastle.conf \
    && echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/10-sandcastle.conf \
    && echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/10-sandcastle.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

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

ENTRYPOINT ["/entrypoint.sh"]
