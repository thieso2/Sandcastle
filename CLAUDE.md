# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sandcastle is a self-hosted shared sandbox platform. Users get isolated Incus system containers with SSH access and a full Docker daemon inside. The stack is Rails 8.1 (Ruby 4.0) for the web/API backend and a Go CLI for user interaction. The Rails app itself runs in Docker (deployed via Kamal); only sandboxes run as Incus instances on ZFS.

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
- `SandboxManager` — Instance lifecycle (create/destroy/start/stop/snapshot/restore). Uses `IncusClient` to talk to the Incus daemon via Unix socket. Also handles in-sandbox Tailscale setup via cloud-init.
- `SystemStatus` — Incus server stats for admin dashboard

All service errors inherit from `ServiceName::Error` and are rescued in `Api::BaseController` as 422 JSON responses. `IncusClient::NotFoundError` maps to 404, `ActiveRecord::RecordNotFound` to 404, `RecordInvalid` to 422.

### IncusClient

`app/lib/incus_client.rb` — thin REST client over the Incus Unix socket (`/var/lib/incus/unix.socket`). Uses the `net_http_unix` gem. Key patterns:
- Mutating operations return 202 → polls `GET /1.0/operations/{uuid}/wait?timeout=30`
- 404 → `IncusClient::NotFoundError`
- All other errors → `IncusClient::Error`
- Methods: `create_instance`, `get_instance`, `delete_instance`, `change_state`, `get_instance_state`, `exec` (with `record-output: true`), `push_file`, `create_snapshot`, `list_snapshots`, `delete_snapshot`, `restore_snapshot`, `copy_instance`, `rename_instance`, `create_network`, `delete_network`, `add_device`, `remove_device`, `server_info`

### Instance Model

Each sandbox = one Incus system container with:
- `security.nesting=true` (enables Docker-in-Docker)
- SSH forwarded via proxy device (host port 2201–2299 → container port 22)
- User home bind-mounted from `/data/users/{name}/home` via disk device
- Optional persistent volume at `/data/sandboxes/{name}/vol:/workspace` via disk device
- Optional Tailscale installed and configured via cloud-init (`tailscale up --authkey=... --ssh`)
- Cloud-init provisioning (creates user, injects SSH key, enables Docker + SSH services)

The sandbox image (`images/sandbox/build-image.sh`) is Ubuntu 24.04 with Docker, SSH, Tailscale, and dev tools. Published as `sandcastle-sandbox` in the local Incus image store.

**Key differences from old Docker+Sysbox setup:**
- No runc pinning needed (Incus system containers handle this natively)
- Docker runs as a systemd service (not manually started in entrypoint)
- Cloud-init replaces `entrypoint.sh` for provisioning
- Snapshots are instant ZFS CoW operations (not `docker commit`)
- SSH port forwarding via Incus proxy device (not Docker port binding)

### Tailscale System

Tailscale runs directly inside each sandbox (no sidecar containers). Users store a reusable Tailscale auth key in the app (encrypted via `encrypts :tailscale_auth_key`). When `--tailscale` is passed on sandbox create (or `tailscale_auto_connect` is enabled), cloud-init runs `tailscale up --authkey=KEY --hostname=NAME --ssh`.

- Each sandbox becomes its own Tailscale node, directly reachable from the user's tailnet
- `tailscale_auto_connect` user setting auto-enables Tailscale on new sandboxes
- `SandboxManager#tailscale_ip` queries the sandbox's Tailscale IP via `incus exec tailscale ip --4`
- No sidecars, bridge networks, or per-user Tailscale containers

### Snapshots

Snapshots are per-instance ZFS snapshots (instant, copy-on-write):
- `snapshot` creates an Incus snapshot on the sandbox instance
- `list_snapshots` iterates all active sandboxes and lists their snapshots
- `destroy_snapshot` finds the snapshot by searching across active sandboxes (or uses explicit sandbox name)
- `restore` copies from `instance/snapshot` to a temp instance, deletes original, renames temp back, re-attaches devices

### Background Jobs

Solid Queue (SQLite-backed) with recurring schedule in `config/recurring.yml`:
- `ContainerSyncJob` — every 5 min, reconciles DB sandbox status with actual Incus instance state

### Database

SQLite for everything (primary, cache, queue, cable). Schema has 4 app tables: `users`, `sandboxes`, `api_tokens`, `sessions`. Key constraints:
- Sandbox names and SSH ports are unique only among non-destroyed sandboxes (partial unique indexes: `WHERE status != 'destroyed'`)
- SSH port auto-assigned from 2201–2299 on create
- `container_id` field stores the Incus instance name (e.g., `username-sandboxname`)

### Frontend

ERB templates with Tailwind CSS (v4). Turbo Frames for async container stats. No heavy JS framework — Stimulus controllers only where needed.

## Deployment

- **Host**: `100.79.246.119` (Tailscale IP), SSH user `thies`
- **Registry**: `100.126.147.91:4443` (private, insecure HTTP — configured in `buildkitd.toml`)
- **Deploy**: `kamal deploy` (config in `config/deploy.yml`), or `docker-compose up -d`
- **Host bootstrap**: `bootstrap/sandcastle-bootstrap.sh` (Docker for Kamal, Incus+ZFS for sandboxes, Caddy, UFW)
- **Env vars**: `SECRET_KEY_BASE`, `RAILS_MASTER_KEY`, `SANDCASTLE_HOST`, `SANDCASTLE_DATA_DIR` (default `/data`), `INCUS_SOCKET` (default `/var/lib/incus/unix.socket`)
- **Proxy**: kamal-proxy with `response_timeout: 60`
- The Kamal app container needs `group-add: incus-admin` for Incus socket access
- Incus socket mounted at `/var/lib/incus/unix.socket` into the Rails container

### Image Building

Images are built on the Incus host (not via Dockerfile):
- `bash images/sandbox/build-image.sh` → publishes `sandcastle-sandbox` (includes Tailscale)
- `images/sandbox/sandcastle-profile.yaml` — Incus profile with nesting, syscall interception, 50GB root disk

### Migration from Docker+Sysbox

To migrate an existing deployment:
1. Run `bootstrap/sandcastle-bootstrap.sh` on the host (installs Incus+ZFS alongside Docker)
2. Build image: `bash images/sandbox/build-image.sh`
3. Deploy new Rails app: `kamal deploy`
4. Cutover: `bin/rails incus:cutover` (marks old sandboxes as destroyed; user homes preserved)
5. Users recreate sandboxes — home directories are re-mounted automatically
