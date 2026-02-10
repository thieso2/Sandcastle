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

### Go CLI (vendor/sandcastle-cli/)

```bash
cd vendor/sandcastle-cli && make build    # Build binary → ./sandcastle
cd vendor/sandcastle-cli && go build ./...  # Quick compile check
```

Go module path is `github.com/sandcastle/cli`. When adding a new feature: add types to `api/types.go`, client methods to `api/client.go`, then the Cobra command in `cmd/`.

### Full CI

```bash
bin/ci    # Runs rubocop → brakeman → bundler-audit → importmap audit → tests → system tests
```

## Architecture

### Two Auth Systems

- **Web UI**: Session-based via `Authentication` concern → cookie `session_id`
- **API**: Bearer token via `ApiAuthentication` concern → `Authorization: Bearer sc_PREFIX_SECRET` header, bcrypt digest stored in `api_tokens` table. Token format: `sc_{8-char prefix}_{48-char secret}` (prefix stored plain, secret bcrypt-hashed)

Both concerns provide `require_admin!` for admin-only actions.

### Service Objects

Business logic lives in plain Ruby service classes, not models or controllers:
- `SandboxManager` — Container lifecycle (create/destroy/start/stop/snapshot/restore). Uses the `docker-api` gem to talk to the Docker daemon via socket.
- `TailscaleManager` — Per-user Tailscale sidecar lifecycle (see Tailscale section below)
- `SystemStatus` — Docker daemon stats for admin dashboard

All service errors inherit from `ServiceName::Error` and are rescued in `Api::BaseController` as 422 JSON responses. `ActiveRecord::RecordNotFound` maps to 404, `RecordInvalid` to 422.

### Container Model

Each sandbox = one Sysbox container (`sysbox-runc` runtime) with:
- SSH on a unique host port (range 2201–2299)
- User home bind-mounted from `/data/users/{name}/home`
- Optional persistent volume at `/data/sandboxes/{name}/vol:/workspace`
- Optional Tailscale connectivity via per-user bridge network + sidecar

The sandbox image (`images/sandbox/`) is Ubuntu 24.04 with Docker-in-Docker, SSH server, and dev tools. Key details:
- runc pinned to v1.1.15 (1.2+ fails in Sysbox)
- Docker daemon MTU matches container's eth0 to avoid fragmentation
- The `entrypoint.sh` creates the user, injects SSH keys, starts dockerd, then runs sshd

### Tailscale System

Per-user Tailscale sidecars connect sandbox containers to a user's own tailnet. Each user gets their own sidecar joining **their** tailnet (not a shared one).

**Two authentication flows in `TailscaleManager`:**
- **Auth key flow** (`enable`): One-shot with `TS_AUTHKEY` env var, uses default `containerboot` entrypoint
- **Interactive login flow** (`start_login` → `check_login`): Overrides entrypoint to `tailscaled` directly, runs `tailscale up --reset --timeout=10s` to get a browser login URL, polls `tailscale status --json` for `BackendState == "Running"`

**User `tailscale_state` field:** `disabled` → `pending` (during interactive login) → `enabled`

**Sidecar architecture:**
- Bridge network: `sc-ts-net-{username}` with subnet `172.{100+user_id%100}.0.0/16`
- Container: `sc-ts-{username}` running `tailscale/tailscale:latest`
- State persisted at `/data/users/{name}/tailscale`
- Advertises subnet routes so sandboxes on the bridge are reachable from the tailnet
- `tailscale_auto_connect` user setting auto-joins new sandboxes to the bridge network

**Important:** `containerboot` (default Tailscale image entrypoint) conflicts with manual `tailscale up` when no auth key is provided. The interactive flow must override the entrypoint to run `tailscaled` directly.

### Background Jobs

Solid Queue (SQLite-backed) with recurring schedule in `config/recurring.yml`:
- `ContainerSyncJob` — every 5 min, reconciles DB sandbox status with actual Docker container state and Tailscale sidecar health

### Database

SQLite for everything (primary, cache, queue, cable). Schema has 4 app tables: `users`, `sandboxes`, `api_tokens`, `sessions`. Key constraints:
- Sandbox names and SSH ports are unique only among non-destroyed sandboxes (partial unique indexes: `WHERE status != 'destroyed'`)
- SSH port auto-assigned from 2201–2299 on create

### Frontend

ERB templates with Tailwind CSS (v4). Turbo Frames for async container stats. No heavy JS framework — Stimulus controllers only where needed. The Tailscale pending state uses vanilla JS polling (fetch every 3s) to detect auth completion.

## Deployment

- **Host**: `100.106.185.92` (Tailscale IP), SSH user `thies`
- **Registry**: `100.126.147.91:4443` (private, insecure HTTP — configured in `buildkitd.toml`)
- **Deploy**: `kamal deploy` (config in `config/deploy.yml`), or `docker-compose up -d`
- **Host bootstrap**: `bootstrap/sandcastle-bootstrap.sh` (Docker, Sysbox, Caddy, UFW)
- **Env vars**: `SECRET_KEY_BASE`, `RAILS_MASTER_KEY`, `SANDCASTLE_HOST`, `SANDCASTLE_DATA_DIR` (default `/data`)
- **Proxy**: kamal-proxy with `response_timeout: 60` (needed for Tailscale login flow which blocks ~13s)
- The Kamal app container needs `group-add: 988` for Docker socket access
