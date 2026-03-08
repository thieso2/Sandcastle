# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sandcastle is a self-hosted shared Docker sandbox platform. Users get isolated Sysbox containers with SSH access and a full Docker daemon inside. The stack is Rails 8.1 (Ruby 4.0) for the web/API backend and a Go CLI for user interaction.

> **Important:** The container runtime is **Docker + Sysbox** (`sysbox-runc`). Incus/LXD is **not** used and should never be introduced. All container operations go through the `docker-api` gem via the Docker socket.

## Commands

### Rails App

```bash
bin/dev                              # Start dev server (web + Tailwind watcher via foreman)
bin/rails test                       # Run all tests (Minitest)
bin/rails test test/models/user_test.rb          # Run a single test file
bin/rails test test/models/user_test.rb:10       # Run a single test by line
bin/rails db:migrate                 # Run pending migrations
bin/rails db:prepare                 # Migrate + seed
bin/rubocop                          # Lint (rubocop-rails-omakase style)
bin/brakeman                         # Security scan
```

### Local Dev Environment

There is no local Postgres — use `mise run deploy:dev` to bring up the full stack (Postgres, Rails, worker, Traefik) in Docker. The dev compose file mounts source code for live reload. Postgres is on host port 7633 to avoid conflicts with OrbStack. See `LOCAL.md` for details.

```bash
mise run deploy:dev              # Start (builds image + runs)
mise run deploy:dev:down         # Stop
mise run deploy:dev:reset        # Nuclear reset (removes volumes)
docker exec -it sandcastle-web ./bin/rails db:migrate   # Run migrations
docker exec -it sandcastle-web ./bin/rails console       # Rails console
```

### Go CLI (vendor/sandcastle-cli/)

```bash
cd vendor/sandcastle-cli && make build    # Build binary → ./sandcastle
cd vendor/sandcastle-cli && go build ./...  # Quick compile check
```

Go module path is `github.com/sandcastle/cli`. When adding a new feature: add types to `api/types.go`, client methods to `api/client.go`, then the Cobra command in `cmd/`.

### Patching Live

To apply a single file change directly to the running production instance without a full redeploy:

```bash
scp path/to/file.rb sandcastle@sandman:/tmp/file.rb
ssh sandcastle@sandman 'docker cp /tmp/file.rb sandcastle-web:/rails/path/to/file.rb && docker restart sandcastle-web'
```

### Full CI

```bash
bin/ci    # Runs rubocop → brakeman → bundler-audit → importmap audit → tests → system tests
```

### Releasing

```bash
mise run release          # Bump patch (v0.1.14 → v0.1.15), tag, push
mise run release:minor    # Bump minor (v0.1.14 → v0.2.0), tag, push
mise run release:major    # Bump major (v0.1.14 → v1.0.0), tag, push
```

Pushing a tag triggers the GitHub Actions `release.yml` workflow which:
1. Builds CLI binaries via GoReleaser (cross-compiled for linux/darwin × amd64/arm64)
2. Creates a GitHub release with signed/notarized archives
3. Auto-updates the Homebrew formula in `thieso2/homebrew-tap` (requires `HOMEBREW_TAP_GITHUB_TOKEN` secret)

CLI version is injected at build time via ldflags (`-X github.com/sandcastle/cli/cmd.Version`).

## Architecture

### BTRFS Support

Sandcastle automatically detects and uses BTRFS subvolumes when the filesystem supports it:

**Installer** (`setup_btrfs_subvolumes()` in `installer.sh`):
- Detects if `$SANDCASTLE_HOME` is on BTRFS
- Creates subvolumes for:
  - `$SANDCASTLE_HOME/data/users` (all user data)
  - `$SANDCASTLE_HOME/data/sandboxes` (sandbox volumes)
  - `$SANDCASTLE_HOME/data/postgres` (database)
  - `$SANDCASTLE_HOME/data/wetty` (terminal keys)
  - `$SANDCASTLE_HOME/data/traefik` (proxy config)
  - `$DOCKYARD_ROOT/docker` (Docker data)

**Rails** (`BtrfsHelper` service):
- Creates per-user subvolumes: `/data/users/<username>`
- Creates per-data-path subvolumes: `/data/users/<username>/data/<path>`
- Falls back gracefully to regular directories if BTRFS operations fail
- Uses `sudo -n /usr/bin/btrfs subvolume {show,create}` (restricted passwordless sudo)

**Security**: Passwordless sudo limited to BTRFS subvolume commands only (`/etc/sudoers.d/sandcastle`).

Benefits: efficient snapshots, better CoW performance, per-directory quotas.

### Two Auth Systems

- **Web UI**: Session-based via `Authentication` concern → cookie `session_id`
- **API**: Bearer token via `ApiAuthentication` concern → `Authorization: Bearer sc_PREFIX_SECRET` header, bcrypt digest stored in `api_tokens` table. Token format: `sc_{8-char prefix}_{48-char secret}` (prefix stored plain, secret bcrypt-hashed)

Both concerns provide `require_admin!` for admin-only actions.

### Service Objects

Business logic lives in plain Ruby service classes, not models or controllers:
- `SandboxManager` — Container lifecycle (create/destroy/start/stop/snapshot/restore). Uses the `docker-api` gem to talk to the Docker daemon via socket.
- `TerminalManager` — WeTTY web terminal sidecar lifecycle (see Web Terminal section below)
- `TailscaleManager` — Per-user Tailscale sidecar lifecycle (see Tailscale section below)
- `SystemStatus` — Docker daemon stats for admin dashboard

All service errors inherit from `ServiceName::Error` and are rescued in `Api::BaseController` as 422 JSON responses. `ActiveRecord::RecordNotFound` maps to 404, `RecordInvalid` to 422.

### Container Model

Each sandbox = one Sysbox container (`sysbox-runc` runtime) with:
- SSH on a unique host port (range 2201–2299)
- User home bind-mounted from `/data/users/{name}/home`
- Optional persistent data volume at `/data/users/{name}/data/{path}:/persisted`
- Optional Tailscale connectivity via per-user bridge network + sidecar

The sandbox image (`images/sandbox/`) is Ubuntu 24.04 with Docker-in-Docker, SSH server, and dev tools. Key details:
- runc pinned to v1.1.15 (1.2+ fails in Sysbox)
- Docker daemon MTU matches container's eth0 to avoid fragmentation
- The `entrypoint.sh` creates the user, injects SSH keys, starts dockerd, then runs sshd

### Web Terminal (WeTTY)

Browser-based terminal access via [WeTTY](https://github.com/butlerx/wetty) sidecar containers. Each terminal open spawns an ephemeral WeTTY container that SSH's into the sandbox.

**Architecture:**
- WeTTY container: `sc-wetty-{user}-{sandbox}` on the `sandcastle-web` Docker network
- SSH keypair: generated per-open in `/data/wetty/{full_name}/`, private key copied into WeTTY container via `docker exec` + base64 (bind mounts don't work because Rails runs inside a container with a named Docker volume for `/data`)
- Traefik dynamic config: `terminal-{id}.yml` in `/data/traefik/dynamic/` with forwardAuth middleware
- WeTTY uses `COMMAND` env var with full SSH command including tmux (`tmux new-session -A -s main`)
- `SANDCASTLE_TERMINAL_URL` env var controls the redirect target (needed when Rails is behind a different port than Traefik)

**ForwardAuth flow (`TerminalController#auth`):**
- Traefik sends each request to `http://sandcastle-web:80/terminal/auth` with `X-Forwarded-Uri`
- Rails validates the session cookie and sandbox ownership (owner or admin)
- Unauthenticated users get redirected to the login page with `return_to_after_authenticating` set to the terminal URL
- Returns 200 to allow, redirect to login, or 401 for unauthorized

**Important gotchas:**
- Sandbox entrypoint must **append** SSH keys (not overwrite) because all sandboxes for the same user share `/home/{user}` via bind mount
- `remove_pubkey` uses end-of-line regex anchor (`$`) to avoid substring collisions between sandbox names
- Traefik config is written early in `TerminalManager#open` (before container creation) with a 1-second sleep to allow Traefik to detect the new route before the browser redirect arrives

### Tailscale System

Per-user Tailscale sidecars connect sandbox containers to a user's own tailnet. Each user gets their own sidecar joining **their** tailnet (not a shared one).

**Two authentication flows in `TailscaleManager`:**
- **Auth key flow** (`enable`): One-shot with `TS_AUTHKEY` env var, uses default `containerboot` entrypoint
- **Interactive login flow** (`start_login` → `check_login`): Overrides entrypoint to `tailscaled` directly, runs `tailscale up --reset --timeout=10s` to get a browser login URL, polls `tailscale status --json` for `BackendState == "Running"`

**User `tailscale_state` field:** `disabled` → `pending` (during interactive login) → `enabled`

**Sidecar architecture:**
- Bridge network: `sc-ts-net-{username}` with a random `/24` subnet drawn from `DOCKYARD_POOL_BASE` (e.g. `10.89.42.0/24`)
- Container: `sc-ts-{username}` running `tailscale/tailscale:latest`
- State persisted at `/data/users/{name}/tailscale`
- Advertises subnet routes so sandboxes on the bridge are reachable from the tailnet
- `tailscale_auto_connect` user setting auto-joins new sandboxes to the bridge network

**Important:** `containerboot` (default Tailscale image entrypoint) conflicts with manual `tailscale up` when no auth key is provided. The interactive flow must override the entrypoint to run `tailscaled` directly.

### Networking Invariants — Do Not Change Without Asking

The Dockyard Docker daemon (`sc_docker`) and the Rails app share a single private address space. **All of the following must stay consistent or Tailscale sidecars (and sandbox containers) will lose internet access.**

```
SANDCASTLE_PRIVATE_NET  (e.g. 10.89.0.0/16)
└── DOCKYARD_POOL_BASE  = same /16  (passed to dockerd --default-address-pool)
    ├── DOCKYARD_BRIDGE_CIDR  = first /24 (e.g. 10.89.0.1/24) — sc_docker0 bridge
    ├── DOCKYARD_FIXED_CIDR   = same /24 (e.g. 10.89.0.0/24)  — static container IPs
    ├── sandcastle-web network — allocated from the pool (e.g. 10.89.1.0/24)
    └── sc-ts-net-{user}      — random /24 from the pool (e.g. 10.89.42.0/24)
```

**iptables rules** (set by the `sc_docker` systemd unit at startup, NOT by dockerd):
- `POSTROUTING MASQUERADE` for the entire `DOCKYARD_POOL_BASE` /16 → gives all containers internet via NAT
- `FORWARD ACCEPT` for src/dst within the /16 → allows container-to-container and container-to-internet traffic

**Critical constraints:**
1. `DOCKYARD_POOL_BASE` **must be passed** to the Rails `web` and `worker` containers as an env var — `subnet_for()` in `TailscaleManager` reads it to pick a subnet within the masqueraded range. If it is missing or mismatched, Tailscale sidecars get a subnet outside the MASQUERADE rule and have no internet.
2. The Dockyard daemon runs with `--iptables=false` — it never touches iptables itself. All rules live in the systemd unit. **Do not add Docker iptables management** (`--iptables=true`) without updating the unit's ExecStartPre rules accordingly.
3. `SANDCASTLE_PRIVATE_NET` / `DOCKYARD_POOL_BASE` must not overlap with the host's existing routes. `gen-env` picks a non-conflicting /16 automatically — do not hard-code a range without checking.
4. Changing `SANDCASTLE_PRIVATE_NET` on an existing install requires destroying all containers and networks first — existing containers have IPs baked in.

### Background Jobs

Solid Queue with recurring schedule in `config/recurring.yml`:
- `ContainerSyncJob` — every 5 min, reconciles DB sandbox status with actual Docker container state and Tailscale sidecar health

### Database

PostgreSQL with 4 separate databases in production (`config/database.yml`):
- `sandcastle_production` — primary (users, sandboxes, api_tokens, sessions)
- `sandcastle_production_cache` — Solid Cache
- `sandcastle_production_queue` — Solid Queue
- `sandcastle_production_cable` — Solid Cable

The primary database is created by PostgreSQL's `POSTGRES_DB` env var. The other 3 are created by a PostgreSQL init script (`docker/postgres/init-databases.sh`, mounted into `/docker-entrypoint-initdb.d/`). The installer writes this script to `$SANDCASTLE_HOME/etc/postgres/init-databases.sh`. When adding or removing Solid* databases, update both the init script and `database.yml`.

**Database password preservation:**
- Password stored in `$SANDCASTLE_HOME/data/postgres/.secrets` (600 perms)
- On fresh install: generates random password and saves to `.secrets`
- On reinstall: reuses password from `.secrets` to match existing postgres data
- Preserved during uninstall/reset (user data)
- Prevents authentication failures when reinstalling with existing database

Key constraints:
- Sandbox names and SSH ports are unique only among non-destroyed sandboxes (partial unique indexes: `WHERE status != 'destroyed'`)
- SSH port auto-assigned from 2201–2299 on create

### Frontend

ERB templates with Tailwind CSS (v4). Turbo Frames for async container stats. No heavy JS framework — Stimulus controllers only where needed. The Tailscale pending state uses vanilla JS polling (fetch every 3s) to detect auth completion.

## Deployment

- **Host**: `100.106.185.92` (Tailscale IP), SSH user `thies`; SSH alias `sandman`
- **Sandcastle home on host**: `/sandcastle` (not `/data` — that's the data dir inside containers)
- **Dockyard Docker CLI on host**: `/sandcastle/dockyard/bin/docker` (isolated daemon, not system Docker)
  - To run docker commands on sandman: `ssh sandman "/sandcastle/dockyard/bin/docker ps"`
- **Registry**: `ghcr.io/thieso2/sandcastle` (GitHub Container Registry)
- **Deploy**: `docker-compose up -d` (see `docker-compose.yml`)
- **Host bootstrap**: `bootstrap/sandcastle-bootstrap.sh` (Docker, Sysbox, Caddy, UFW)
- **Env vars**: `SECRET_KEY_BASE`, `RAILS_MASTER_KEY`, `SANDCASTLE_HOST`, `SANDCASTLE_DATA_DIR` (default `/data`)
- **Proxy**: Traefik with `response_timeout: 60` (needed for Tailscale login flow which blocks ~13s)
- The app container needs `group-add: 988` for Docker socket access

## Conventions

- When features are changed or added, update the guide page at `app/views/pages/guide.html.erb` to reflect the new CLI commands and usage.
- **Never edit `installer.sh` directly** — it is generated from `installer/installer.sh.in`. Make all installer changes in `installer/installer.sh.in` and regenerate `installer.sh` from it.
- **Never edit `installer/templates/dockyard.sh`** — Dockyard is an upstream project. If Sandcastle needs changes to the dockyard template, create an issue at `thieso2/dockyard` instead.

## GitHub Actions Workflow

When triggered via `@claude` comments in GitHub issues or PRs:

- **Always complete the full workflow** without asking for approval to commit/push/create PRs
- The workflow grants explicit permissions (`--allowedTools`) for git operations
- After implementing changes:
  1. Stage files with `git add`
  2. Commit with descriptive message including `Co-authored-by` trailer
  3. Push to the branch immediately
  4. Provide a link to create a PR (or create it if you have the capability)
- **Do not stop and ask for permission** — the `--allowedTools` configuration is the permission
- Only ask for clarification if requirements are unclear, not for commit/push approval
