FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System tools
RUN apt-get update && apt-get install -y \
    openssh-server sudo curl git tmux vim neovim \
    build-essential \
    jq ripgrep fd-find htop wget unzip ca-certificates net-tools \
    && rm -rf /var/lib/apt/lists/*

# Prefer IPv4 to avoid slow/broken IPv6 connections
RUN sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Docker CLI + daemon (Sysbox makes this safe)
RUN curl -fsSL https://get.docker.com | sh

# Pin runc to 1.1.x — runc 1.2+ added a procfs safety check that fails
# inside sysbox containers (sysbox-fs mounts /proc/sys as separate FUSE)
RUN RUNC_VERSION="v1.1.15" \
    && curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" \
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

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
