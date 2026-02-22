FROM ubuntu:24.04

# Minimal sandbox image for integration tests (~100 MB).
# No Docker-in-Docker, no VNC, no dev tooling — just SSH.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-server \
      sudo && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
