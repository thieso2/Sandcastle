# Thin layer on top of the pre-built base image.
# Changes here (entrypoint, config, scripts) build in seconds.
# To rebuild the base: trigger the "Rebuild Sandbox Base Image" workflow
# or change files in images/sandbox/base/.
FROM golang:1.26-alpine AS oidc-helper-builder
WORKDIR /build
COPY oidc-helper/ .
RUN go test ./... \
    && CGO_ENABLED=0 go build -ldflags="-s -w" -o sandcastle-oidc .

FROM ghcr.io/thieso2/sandcastle-sandbox-base:latest

ARG SANDCASTLE_VERSION=dev

# Always pull latest security patches and package updates.
# CACHE_DATE is set at build time to bust the layer cache on demand.
#
# Hold Docker-stack packages before upgrading: the base image pins
# containerd.io=1.7.27-1 (see Dockerfile.base for rationale — containerd.io ≥ 2.x
# breaks sysbox-runc, nestybox/sysbox#958). Without the hold, `apt-get upgrade`
# installs containerd.io 2.x, which also replaces /usr/bin/runc with a newer
# runc (1.3.3+) whose CVE-2025-52881 fix rejects sysbox's FUSE-backed procfs
# with "unsafe procfs detected" and breaks docker-in-docker inside sandboxes.
# Re-install the pinned runc afterwards as belt-and-suspenders in case an
# older base image (built before the apt-mark hold was added) is used.
ARG CACHE_DATE=0
RUN apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && for i in 1 2 3; do apt-get update && break || sleep 5; done \
    && apt-get upgrade -y \
    && RUNC_VERSION="v1.1.15" \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" \
       -o /usr/bin/runc \
    && chmod +x /usr/bin/runc \
    && rm -rf /var/lib/apt/lists/*

# Google Cloud CLI. Sandcastle injects external-account credentials for GCP
# sandboxes, and gcloud picks them up through CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE.
RUN apt-get update \
    && apt-get install -y apt-transport-https ca-certificates gnupg curl \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
       | gpg --batch --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# Bake version into the image
RUN echo "${SANDCASTLE_VERSION}" > /etc/sandcastle-version

# ssh-agent-switcher — daemon that proxies SSH agent requests to the most
# recent valid forwarded agent socket, surviving tmux detach/reattach.
ARG TARGETARCH
RUN SAS_VERSION="v1.0.1.1-tc" \
    && SAS_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL "https://github.com/thieso2/ssh-agent-switcher/releases/download/${SAS_VERSION}/ssh-agent-switcher-${SAS_ARCH}-unknown-linux-gnu.tar.gz" \
       | tar -xz -C /usr/local/bin ssh-agent-switcher \
    && chmod +x /usr/local/bin/ssh-agent-switcher

# SSH agent forwarding: prefer ssh-agent-switcher daemon socket, fall back
# to the stable symlink maintained by sc-tmux.
RUN printf '# ssh-agent-switcher daemon socket or symlink fallback\nif [ -S "/tmp/ssh-agent.${USER}" ]; then\n    export SSH_AUTH_SOCK="/tmp/ssh-agent.${USER}"\nelif [ -S "$HOME/.ssh/agent_sock" ]; then\n    export SSH_AUTH_SOCK="$HOME/.ssh/agent_sock"\nfi\n' \
       > /etc/profile.d/ssh-agent.sh

# Prepend $HOME/.local/bin to PATH for every user. Home is bind-mounted from
# the host, so /etc/skel/.profile (Ubuntu's default home for this rule) never
# lands in $HOME and the user's local-bin would otherwise be off PATH.
# /etc/profile.d/ covers login shells; the same line in /etc/bash.bashrc
# covers non-login interactive bash shells.
RUN printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' \
       > /etc/profile.d/sandcastle-path.sh \
    && chmod 0644 /etc/profile.d/sandcastle-path.sh \
    && printf '\n# sandcastle: $HOME/.local/bin on PATH for non-login interactive shells\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' \
       >> /etc/bash.bashrc

COPY entrypoint.sh /entrypoint.sh
COPY docker-restart.sh /usr/local/bin/docker-restart
COPY sc-tmux.sh /usr/local/bin/sc-tmux
COPY sc-install-brew.sh /usr/local/bin/sc-install-brew
COPY --from=oidc-helper-builder /build/sandcastle-oidc /usr/local/bin/sandcastle-oidc
RUN chmod +x /entrypoint.sh /usr/local/bin/docker-restart /usr/local/bin/sc-tmux /usr/local/bin/sc-install-brew /usr/local/bin/sandcastle-oidc

COPY startchrome.sh /usr/local/bin/google-chrome
RUN chmod +x /usr/local/bin/google-chrome \
    && ln -sf /usr/local/bin/google-chrome /usr/local/bin/startchrome

COPY tmux.conf /etc/tmux.conf
COPY gitconfig /etc/gitconfig

LABEL org.opencontainers.image.source="https://github.com/thieso2/sandcastle"
LABEL org.opencontainers.image.description="Sandcastle sandbox image — Ubuntu 25.10 with Docker-in-Docker, SSH, and dev tools"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${SANDCASTLE_VERSION}"

EXPOSE 22 5900 6080 7681 7682
EXPOSE 60000-61000/udp

ENTRYPOINT ["/entrypoint.sh"]
