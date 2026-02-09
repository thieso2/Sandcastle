# Sandcastle — Shared Docker Sandbox Server

## Overview

Sandcastle is a lightweight platform for sharing a single Hetzner root server among a small group of trusted colleagues. Each user gets their own isolated Docker environment (via SSH on a unique port) where they can create **sandboxes** — Docker-in-Docker containers for running long-lived coding sessions (Claude Code, tmux, etc.).

**Key technology choice:** [Sysbox](https://github.com/nestybox/sysbox) as the container runtime. Sysbox enables unprivileged Docker-in-Docker — each user container runs its own Docker daemon without `--privileged`, using Linux user namespaces for isolation. This is the cleanest solution for "Docker inside Docker" without security compromises.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Hetzner Root Server (Ubuntu 24.04, Docker + Sysbox)            │
│  1 public IP: 203.0.113.10                                      │
│                                                                  │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  Sandcastle Rails App (port 443, HTTPS)              │       │
│  │  - User CRUD, sandbox CRUD, status dashboard         │       │
│  │  - API for Go CLI                                    │       │
│  │  - Calls Docker Engine API to manage containers      │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │ User Container   │  │ User Container   │  │ User Container  │ │
│  │ "alice"          │  │ "bob"            │  │ "carol"         │ │
│  │ SSH on :2201     │  │ SSH on :2202     │  │ SSH on :2203    │ │
│  │ runtime: sysbox  │  │ runtime: sysbox  │  │ runtime: sysbox │ │
│  │                  │  │                  │  │                 │ │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │                 │ │
│  │  │ Sandbox 1  │  │  │  │ Sandbox 1  │  │  │  (no sandboxes  │ │
│  │  │ (DinD)     │  │  │  │ (DinD)     │  │  │   yet)          │ │
│  │  └────────────┘  │  │  └────────────┘  │  │                 │ │
│  │  ┌────────────┐  │  │                  │  │                 │ │
│  │  │ Sandbox 2  │  │  │                  │  │                 │ │
│  │  │ (DinD)     │  │  │                  │  │                 │ │
│  │  └────────────┘  │  │                  │  │                 │ │
│  └─────────────────┘  └─────────────────┘  └────────────────┘  │
│                                                                  │
│  Volumes: /data/users/{name}/home     (persistent home)          │
│           /data/users/{name}/docker   (Docker cache per user)    │
│           /data/sandboxes/{id}/vol    (optional persistent vols) │
└─────────────────────────────────────────────────────────────────┘
```

### The Three Layers

1. **Host** — Ubuntu 24.04 with Docker + Sysbox. Runs the Rails web app (in a container) and manages everything.

2. **User Container** — One per user, launched with `--runtime=sysbox-runc`. Contains SSH server + Docker daemon. Each user SSHes directly into their container on a unique port. This is their "home machine."

3. **Sandbox** — A Docker container *inside* the user container. Created by the user (or via CLI/API). Pre-loaded with dev tools, tmux, Claude Code, etc. This is where actual work happens.

Why the extra layer? The user container provides Docker daemon isolation (each user has their own image cache, networks, etc.) while sandboxes provide disposable/reproducible work environments within that.

---

## Components

### 1. Host Setup (Ubuntu 24.04 on Hetzner)

**Recommended server:** Hetzner AX52 or AX102 (AMD Ryzen, 64-128 GB RAM, NVMe SSD). For 2-5 users with a few sandboxes each, 64 GB is comfortable.

**Install:**
- Docker Engine (latest stable)
- Sysbox CE (`sysbox-ce` package from GitHub releases)
- Caddy or Traefik as reverse proxy (HTTPS for web UI)
- UFW firewall: allow 22 (admin SSH), 443 (web), 2201-2220 (user SSH range)

**Directory structure:**
```
/data/
  users/
    alice/
      home/          # bind-mounted as /home/alice in user container
      docker/        # bind-mounted as /var/lib/docker in user container
    bob/
      home/
      docker/
  sandboxes/
    <uuid>/
      vol/           # optional persistent volume for sandbox
  sandcastle/
    db/              # SQLite or PostgreSQL data
    config/          # app config
```

### 2. User Container Image

```dockerfile
# sandcastle-user-env
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    openssh-server \
    sudo \
    curl \
    git \
    tmux \
    htop \
    jq \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI + daemon (Sysbox makes this work without --privileged)
RUN curl -fsSL https://get.docker.com | sh

# SSH config
RUN mkdir /var/run/sshd
RUN sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
RUN sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
RUN sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# User will be created at container start via entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
```

**entrypoint.sh:**
```bash
#!/bin/bash
set -e

USERNAME=${SANDCASTLE_USER:-user}
SSH_PUB_KEY=${SANDCASTLE_SSH_KEY:-""}

# Create user if not exists
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,docker "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
fi

# Setup SSH key
if [ -n "$SSH_PUB_KEY" ]; then
    mkdir -p /home/$USERNAME/.ssh
    echo "$SSH_PUB_KEY" > /home/$USERNAME/.ssh/authorized_keys
    chmod 700 /home/$USERNAME/.ssh
    chmod 600 /home/$USERNAME/.ssh/authorized_keys
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
fi

# Start Docker daemon in background
dockerd &>/var/log/dockerd.log &

# Wait for Docker to be ready
for i in $(seq 1 30); do
    docker info &>/dev/null && break
    sleep 1
done

# Pre-pull sandbox base image if not cached
docker pull sandcastle-sandbox:latest 2>/dev/null || true

# Start SSH
exec /usr/sbin/sshd -D
```

**Launching a user container (what the Rails app does):**
```bash
docker run -d \
  --name sandcastle-user-alice \
  --runtime=sysbox-runc \
  --hostname alice-sandbox \
  -p 2201:22 \
  -v /data/users/alice/home:/home/alice \
  -v /data/users/alice/docker:/var/lib/docker \
  -e SANDCASTLE_USER=alice \
  -e SANDCASTLE_SSH_KEY="ssh-ed25519 AAAA... alice@laptop" \
  --restart unless-stopped \
  sandcastle-user-env:latest
```

### 3. Sandbox Base Image

This is the image used *inside* user containers to create sandboxes:

```dockerfile
# sandcastle-sandbox
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    tmux \
    vim \
    neovim \
    python3 \
    python3-pip \
    nodejs \
    npm \
    jq \
    ripgrep \
    fd-find \
    htop \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Nice tmux config
COPY tmux.conf /etc/tmux.conf

# Working directory
WORKDIR /workspace

# Default: start tmux session
CMD ["tmux", "new-session", "-s", "main"]
```

### 4. Rails Web Application

**Models:**

```
User
  - name: string (unique, lowercase, used as unix username)
  - ssh_public_key: text
  - ssh_port: integer (unique, auto-assigned from 2201+)
  - status: enum (active, suspended)
  - created_at, updated_at

Sandbox
  - user_id: references User
  - name: string (unique per user)
  - container_id: string (Docker container ID inside user's Docker)
  - image: string (default: "sandcastle-sandbox:latest")
  - status: enum (running, stopped, destroyed)
  - persistent_volume: boolean (default: false)
  - volume_path: string (nullable)
  - created_at, updated_at
```

**API Endpoints:**

```
# Authentication: API token (simple shared secret or per-user tokens)

# Users (admin only)
POST   /api/users              { name, ssh_public_key }
GET    /api/users
GET    /api/users/:name
DELETE /api/users/:name
PATCH  /api/users/:name        { ssh_public_key, status }

# Sandboxes (scoped to authenticated user)
POST   /api/sandboxes          { name, image?, persistent_volume? }
GET    /api/sandboxes
GET    /api/sandboxes/:name
DELETE /api/sandboxes/:name    ?keep_volume=true
POST   /api/sandboxes/:name/stop
POST   /api/sandboxes/:name/start
POST   /api/sandboxes/:name/connect  # returns connection instructions

# System
GET    /api/status             # health, resource usage per user
```

**How the Rails app manages sandboxes:**

The Rails app doesn't create sandboxes directly. Instead, it SSHes (or uses Docker exec) into the user container and runs Docker commands there. This keeps the isolation model clean — sandboxes are always children of the user's Docker daemon.

```ruby
# app/services/sandbox_manager.rb
class SandboxManager
  def create(user, name, image: "sandcastle-sandbox:latest", persistent: false)
    vol_flag = ""
    if persistent
      vol_path = "/data/sandboxes/#{SecureRandom.uuid}/vol"
      FileUtils.mkdir_p(vol_path)
      vol_flag = "-v #{vol_path}:/workspace/persistent"
    end

    cmd = <<~CMD
      docker exec sandcastle-user-#{user.name} \
        docker run -d \
          --name #{name} \
          #{vol_flag} \
          --hostname #{name} \
          #{image}
    CMD

    container_id = `#{cmd}`.strip
    # ... create Sandbox record
  end

  def connect_instructions(user, sandbox)
    {
      ssh_command: "ssh -p #{user.ssh_port} #{user.name}@#{HOST}",
      attach_command: "docker exec -it #{sandbox.name} tmux attach -t main",
      one_liner: "ssh -t -p #{user.ssh_port} #{user.name}@#{HOST} 'docker exec -it #{sandbox.name} tmux attach -t main || docker exec -it #{sandbox.name} bash'"
    }
  end
end
```

**Web Dashboard (minimal):**

- Login (simple token or basic auth — trusted group, remember)
- User list with status indicators (container running/stopped, resource usage)
- Per-user sandbox list with start/stop/destroy/connect buttons
- System overview: CPU, RAM, disk usage
- Live logs viewer (optional, nice to have)

Tech: Rails 8 with Hotwire/Turbo for live updates. SQLite is fine for 2-5 users.

### 5. Go CLI (`sandcastle`)

Installed on each colleague's local machine. Talks to the Rails API for management, SSH for connecting.

```
sandcastle config set-server https://sandbox.example.com
sandcastle config set-token <api-token>

# User management (admin)
sandcastle users create alice --key ~/.ssh/id_ed25519.pub
sandcastle users list
sandcastle users destroy alice

# Sandbox management
sandcastle sandbox create my-project
sandcastle sandbox create my-project --image python:3.12 --persistent
sandcastle sandbox list
sandcastle sandbox destroy my-project
sandcastle sandbox destroy my-project --keep-volume

# Connect (opens SSH + attaches to sandbox tmux)
sandcastle connect my-project

# Quick shortcuts
sandcastle ssh                    # SSH into user container
sandcastle status                 # show all sandboxes + resource usage
```

**`sandcastle connect` implementation (Go):**

```go
func connectSandbox(sandboxName string) error {
    // 1. Get connection info from API
    info, err := apiClient.GetConnectInfo(sandboxName)
    if err != nil {
        return err
    }

    // 2. Ensure sandbox is running
    if info.Status != "running" {
        fmt.Println("Starting sandbox...")
        apiClient.StartSandbox(sandboxName)
        time.Sleep(2 * time.Second)
    }

    // 3. SSH + exec into sandbox tmux
    cmd := exec.Command("ssh",
        "-t",
        "-p", strconv.Itoa(info.SSHPort),
        fmt.Sprintf("%s@%s", info.Username, info.Host),
        fmt.Sprintf("docker exec -it %s tmux attach -t main 2>/dev/null || docker exec -it %s bash", sandboxName, sandboxName),
    )
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    return cmd.Run()
}
```

**Config file:** `~/.sandcastle/config.yaml`
```yaml
server: https://sandbox.example.com
token: sc_abc123...
default_image: sandcastle-sandbox:latest
```

---

## Port Allocation

With a single IP, each user gets a unique SSH port:

| User    | SSH Port | Assigned by |
|---------|----------|-------------|
| (admin) | 22       | Host sshd   |
| alice   | 2201     | Rails app   |
| bob     | 2202     | Rails app   |
| carol   | 2203     | Rails app   |
| dave    | 2204     | Rails app   |

Port range 2201-2220 is reserved and opened in UFW. Rails auto-assigns the next available port on user creation.

---

## Lifecycle Flows

### Adding a new colleague

```
Admin (local machine):
  $ sandcastle users create bob --key ~/.ssh/id_bob.pub

Go CLI → POST /api/users { name: "bob", ssh_public_key: "ssh-ed25519 ..." }

Rails app:
  1. Assigns port 2202
  2. Creates /data/users/bob/home and /data/users/bob/docker
  3. Runs: docker run --runtime=sysbox-runc -p 2202:22 ... sandcastle-user-env
  4. Returns { name: "bob", ssh_port: 2202 }

Admin tells Bob:
  "Install sandcastle CLI, set server + token, then:"
  $ ssh -p 2202 bob@sandbox.example.com   # verify access
  $ sandcastle sandbox create dev          # create first sandbox
  $ sandcastle connect dev                 # start working
```

### Creating and using a sandbox

```
Bob (local machine):
  $ sandcastle sandbox create ml-experiment --persistent

Go CLI → POST /api/sandboxes { name: "ml-experiment", persistent_volume: true }

Rails app:
  1. docker exec sandcastle-user-bob docker run -d --name ml-experiment \
       -v /data/sandboxes/<uuid>/vol:/workspace/persistent \
       sandcastle-sandbox:latest
  2. Returns { name: "ml-experiment", status: "running" }

Bob:
  $ sandcastle connect ml-experiment
  # Drops into tmux session inside the sandbox container
  # Can run: claude, docker, git, pip install, etc.
  # Persistent data goes in /workspace/persistent
  # Everything else is ephemeral (destroyed with sandbox)
```

### Destroying a sandbox (keeping volume)

```
Bob:
  $ sandcastle sandbox destroy ml-experiment --keep-volume

Rails app:
  1. docker exec sandcastle-user-bob docker stop ml-experiment
  2. docker exec sandcastle-user-bob docker rm ml-experiment
  3. Marks sandbox as destroyed, keeps volume_path
  4. Bob can create a new sandbox mounting the same volume later
```

---

## Server Bootstrap Script

Full setup script for a fresh Hetzner root server:

```bash
#!/bin/bash
# sandcastle-bootstrap.sh
# Run as root on a fresh Ubuntu 24.04 Hetzner root server

set -euo pipefail

DOMAIN=${1:-"sandbox.example.com"}

echo "=== Sandcastle Bootstrap ==="

# 1. System updates
apt-get update && apt-get upgrade -y

# 2. Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# 3. Install Sysbox
SYSBOX_VERSION="0.6.5"
wget https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb
apt-get install -y ./sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb
rm sysbox-ce_*.deb

# Verify
docker info | grep -i sysbox && echo "Sysbox installed OK"

# 4. Create data directories
mkdir -p /data/{users,sandboxes,sandcastle/{db,config}}

# 5. Firewall
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp       # admin SSH
ufw allow 443/tcp      # web UI (HTTPS)
ufw allow 2201:2220/tcp # user SSH ports
ufw --force enable

# 6. Install Caddy (reverse proxy + auto HTTPS)
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy

# Caddy config
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    reverse_proxy localhost:3000
}
EOF

systemctl restart caddy

# 7. Build images
echo "Building sandcastle images..."

# User environment image
mkdir -p /opt/sandcastle/images/user-env
# (copy Dockerfile + entrypoint.sh here)
# docker build -t sandcastle-user-env:latest /opt/sandcastle/images/user-env/

# Sandbox base image
mkdir -p /opt/sandcastle/images/sandbox
# (copy Dockerfile + tmux.conf here)
# docker build -t sandcastle-sandbox:latest /opt/sandcastle/images/sandbox/

# 8. Deploy Rails app (as Docker container)
# docker run -d --name sandcastle-web \
#   -p 3000:3000 \
#   -v /data/sandcastle/db:/app/db \
#   -v /data/sandcastle/config:/app/config/credentials \
#   -v /var/run/docker.sock:/var/run/docker.sock \
#   sandcastle-web:latest

echo "=== Bootstrap complete ==="
echo "Next steps:"
echo "  1. Point DNS for ${DOMAIN} to this server's IP"
echo "  2. Build and start the sandcastle-web container"
echo "  3. Create your first user: sandcastle users create <name> --key <key>"
```

---

## Security Notes (Trust Model)

Since all users are trusted colleagues:

- **No multi-tenant hardening** — Sysbox provides reasonable isolation, but we're not defending against malicious insiders.
- **API auth** — Simple shared token or per-user tokens. No OAuth/OIDC complexity.
- **SSH keys only** — No passwords anywhere.
- **Host SSH (port 22)** — Only for the admin. Users cannot access the host directly.
- **Docker socket** — The Rails app container mounts the host Docker socket to manage user containers. This is the one privileged component. The user containers do NOT have access to the host socket (Sysbox isolates them).
- **Resource limits** — Optional but recommended: set `--memory` and `--cpus` on user containers to prevent one person from starving others.

---

## Resource Limits (Recommended)

For a 128 GB / 16-core server with 5 users:

```bash
docker run ... \
  --memory=24g \
  --cpus=3 \
  --storage-opt size=100G \
  ...
```

This leaves headroom for the host OS and Rails app. Adjust based on actual server specs.

---

## File Structure (Repository)

```
sandcastle/
├── README.md
├── server/                    # Rails app
│   ├── Gemfile
│   ├── app/
│   │   ├── controllers/
│   │   │   └── api/
│   │   │       ├── users_controller.rb
│   │   │       └── sandboxes_controller.rb
│   │   ├── models/
│   │   │   ├── user.rb
│   │   │   └── sandbox.rb
│   │   ├── services/
│   │   │   ├── user_manager.rb
│   │   │   └── sandbox_manager.rb
│   │   └── views/             # Hotwire dashboard
│   ├── config/
│   ├── db/
│   └── Dockerfile
├── cli/                       # Go CLI
│   ├── main.go
│   ├── cmd/
│   │   ├── root.go
│   │   ├── users.go
│   │   ├── sandbox.go
│   │   ├── connect.go
│   │   └── config.go
│   ├── api/
│   │   └── client.go
│   └── go.mod
├── images/
│   ├── user-env/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   └── sandbox/
│       ├── Dockerfile
│       └── tmux.conf
├── bootstrap/
│   └── sandcastle-bootstrap.sh
└── docker-compose.yml         # for the Rails app + dependencies
```

---

## Implementation Order

1. **Phase 1: Foundation** — Bootstrap script, user-env image, sandbox image. Manual user creation via Docker CLI. Verify SSH + DinD works end-to-end.

2. **Phase 2: Rails API** — User CRUD, sandbox CRUD, Docker integration. API endpoints working.

3. **Phase 3: Go CLI** — `users`, `sandbox`, `connect`, `config` commands. Talks to Rails API.

4. **Phase 4: Web Dashboard** — User/sandbox status page, start/stop controls, resource monitoring.

5. **Phase 5: Polish** — Resource limits, auto-cleanup of stopped sandboxes, log viewer, sandbox image variants.

---

## Open Decisions

| Decision | Options | Recommendation |
|----------|---------|----------------|
| Database | SQLite vs PostgreSQL | SQLite (≤5 users, zero ops) |
| Rails app deployment | Container vs bare metal | Container (mount Docker socket) |
| Sandbox image distribution | Pre-build on host vs pull from registry | Pre-build on host, `docker save/load` into user containers |
| HTTPS | Caddy vs Let's Encrypt + nginx | Caddy (auto HTTPS, zero config) |
| Web terminal | xterm.js/ttyd vs SSH only | SSH only for v1, web terminal later |
| Claude Code auth | Env var in sandbox vs interactive login | Pass `ANTHROPIC_API_KEY` as env var at sandbox creation |
