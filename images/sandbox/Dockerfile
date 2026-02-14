FROM ubuntu:25.10

ENV DEBIAN_FRONTEND=noninteractive

# System tools
RUN apt-get update && apt-get install -y \
    openssh-server sudo curl git tmux vim neovim \
    build-essential \
    jq ripgrep fd-find htop wget unzip ca-certificates net-tools iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# GUI tools: Xvfb (virtual X server), x11vnc, and Google Chrome
RUN apt-get update && apt-get install -y \
    xvfb x11vnc xfonts-base xfonts-100dpi xfonts-75dpi \
    fonts-liberation libappindicator3-1 libasound2t64 libatk-bridge2.0-0t64 \
    libatk1.0-0t64 libcups2t64 libdbus-1-3 libgdk-pixbuf-2.0-0 libnspr4 libnss3 \
    libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 xdg-utils \
    && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get install -y ./google-chrome-stable_current_amd64.deb \
    && rm google-chrome-stable_current_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

# Prefer IPv4 to avoid slow/broken IPv6 connections
RUN sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Docker CLI + daemon (Sysbox makes this safe)
RUN curl -fsSL https://get.docker.com | sh

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

# Entire CLI — git observability for AI agent sessions (https://entire.io)
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/entireio/cli/releases/latest/download/entire_linux_${ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin entire \
    && chmod +x /usr/local/bin/entire

# Shell config: PATH, mise activation, aliases
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/bash.bashrc \
    && echo 'eval "$(mise activate bash)"' >> /etc/bash.bashrc \
    && echo "alias yolo='claude --dangerously-skip-permissions'" >> /etc/bash.bashrc

# SSH configuration (key-only auth)
RUN mkdir /var/run/sshd \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY tmux.conf /etc/tmux.conf
COPY gitconfig /etc/gitconfig

LABEL org.opencontainers.image.source="https://github.com/thieso2/sandcastle"
LABEL org.opencontainers.image.description="Sandcastle sandbox image — Ubuntu 24.04 with Docker-in-Docker, SSH, and dev tools"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /workspace
EXPOSE 22 5900

ENTRYPOINT ["/entrypoint.sh"]
