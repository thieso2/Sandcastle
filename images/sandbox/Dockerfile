# Thin layer on top of the pre-built base image.
# Changes here (entrypoint, config, scripts) build in seconds.
# To rebuild the base: trigger the "Rebuild Sandbox Base Image" workflow
# or change files in images/sandbox/base/.
FROM ghcr.io/thieso2/sandcastle-sandbox-base:latest

ARG SANDCASTLE_VERSION=dev

# Always pull latest security patches and package updates
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Bake version into the image
RUN echo "${SANDCASTLE_VERSION}" > /etc/sandcastle-version

COPY entrypoint.sh /entrypoint.sh
COPY docker-restart.sh /usr/local/bin/docker-restart
RUN chmod +x /entrypoint.sh /usr/local/bin/docker-restart

COPY startchrome.sh /usr/local/bin/google-chrome
RUN chmod +x /usr/local/bin/google-chrome \
    && ln -sf /usr/local/bin/google-chrome /usr/local/bin/startchrome

COPY tmux.conf /etc/tmux.conf
COPY gitconfig /etc/gitconfig

LABEL org.opencontainers.image.source="https://github.com/thieso2/sandcastle"
LABEL org.opencontainers.image.description="Sandcastle sandbox image — Ubuntu 25.10 with Docker-in-Docker, SSH, and dev tools"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /workspace
EXPOSE 22 5900 6080 7681 7682
EXPOSE 60000-61000/udp

ENTRYPOINT ["/entrypoint.sh"]
