# LOCAL.md

Local development environment guide for Sandcastle. Use this file when debugging locally with Docker Compose.

## Overview

Sandcastle has two local deployment modes:

1. **`mise run deploy:local`** — Production-like environment (builds production image, uses `docker-compose.local.yml`)
2. **`mise run deploy:dev`** — Development environment with live reload (mounts source code, uses `docker-compose.dev.yml`)

Both modes run the full stack (Traefik, PostgreSQL, Rails web, Solid Queue worker) in Docker containers.

## Prerequisites

- Docker with Sysbox runtime installed
- `mise` installed (`brew install mise`)
- `sandcastle-web` network created: `docker network create sandcastle-web`
- Self-signed certificates (auto-generated on first run or created manually)

## Quick Start

### Production-like Local Environment

```bash
# Start (builds image and runs)
mise run deploy:local

# Access at:
#   - https://sandcastle.local:8443 (via Traefik, recommended)
#   - http://sandcastle.local:8080 (via Traefik)

# Stop
mise run deploy:local:down

# Reset (remove all volumes and containers, rebuild)
mise run deploy:local:reset

# View logs
mise run deploy:local:logs
```

### Development Environment (Live Reload)

```bash
# Start (mounts source code)
mise run deploy:dev

# Access at:
#   - https://localhost:8443
#   - http://localhost:8080

# Stop
mise run deploy:dev:down

# Reset
mise run deploy:dev:reset
```

## Commands

### Starting the Environment

```bash
# Production-like (full build)
mise run deploy:local

# Development (live reload)
mise run deploy:dev
```

### Stopping

```bash
# Production-like
mise run deploy:local:down

# Development
mise run deploy:dev:down

# Alternative: stop all containers manually
docker compose -f docker-compose.local.yml down
docker compose -f docker-compose.dev.yml down
```

### Resetting (Clean Slate)

The reset commands remove WeTTY containers, Tailscale sidecars, all volumes, and orphaned containers:

```bash
# Production-like
mise run deploy:local:reset

# Development
mise run deploy:dev:reset
```

This is useful when:
- Database is in a bad state
- Volumes are corrupted
- You want a fresh start

**Warning:** This deletes all data including database, user sandboxes, and Traefik config.

### Viewing Logs

```bash
# Tail all logs (production-like)
mise run deploy:local:logs

# Tail all logs (development)
docker compose -f docker-compose.dev.yml logs -f

# Specific service
docker compose -f docker-compose.local.yml logs -f web
docker compose -f docker-compose.dev.yml logs -f worker

# Last 100 lines
docker logs sandcastle-web --tail 100

# Follow logs for a specific container
docker logs -f sandcastle-web
docker logs -f sandcastle-worker
```

## Inspecting the Environment

### Container Status

```bash
# List all Sandcastle containers
docker ps -a | grep sandcastle

# List all containers (including sandboxes, WeTTY, Tailscale)
docker ps -a

# Filter by name pattern
docker ps -a --filter "name=sc-wetty-"
docker ps -a --filter "name=sc-ts-"
```

### Database Access

```bash
# Enter PostgreSQL container
docker exec -it sandcastle_postgres_1 psql -U sandcastle -d sandcastle_production

# Or for dev environment
docker exec -it sandcastle_postgres_1 psql -U sandcastle -d sandcastle_development

# Run a query
docker exec -it sandcastle_postgres_1 psql -U sandcastle -d sandcastle_production -c "SELECT * FROM users;"

# Check database size
docker exec -it sandcastle_postgres_1 psql -U sandcastle -d sandcastle_production -c "\l+"
```

### Rails Console

```bash
# Production-like environment
docker exec -it sandcastle-web ./bin/rails console

# Development environment (same command)
docker exec -it sandcastle-web ./bin/rails console
```

### Inspect Volumes

```bash
# List volumes
docker volume ls | grep sandcastle

# Inspect a volume
docker volume inspect sandcastle_sandcastle-data
docker volume inspect sandcastle_pgdata

# Browse volume contents (via temporary container)
docker run --rm -v sandcastle_sandcastle-data:/data -it busybox sh
# Inside container: ls -la /data
```

### Network Inspection

```bash
# List networks
docker network ls | grep sandcastle

# Inspect the bridge network
docker network inspect sandcastle-web

# Check what containers are on the network
docker network inspect sandcastle-web -f '{{range .Containers}}{{.Name}} {{end}}'
```

### Traefik Dashboard

Traefik doesn't expose the dashboard by default. To view routing config:

```bash
# Inspect Traefik dynamic config
docker exec -it sandcastle_traefik_1 cat /data/dynamic/rails.yml

# View all dynamic configs
docker exec -it sandcastle_traefik_1 ls -la /data/dynamic/
```

### Docker Socket Access

The web and worker containers need Docker socket access to manage sandbox containers:

```bash
# Check if socket is mounted
docker inspect sandcastle-web | grep -A 5 Mounts | grep docker.sock

# Test Docker access from inside the container
docker exec sandcastle-web docker ps
```

## Environment Variables

### Production-like (`docker-compose.local.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_VERSION` | `dev` | Version tag (auto-set from git) |
| `BUILD_GIT_SHA` | `local` | Git commit SHA (auto-set) |
| `BUILD_GIT_DIRTY` | `false` | Whether working tree is dirty |
| `BUILD_DATE` | current | Build timestamp |
| `SECRET_KEY_BASE` | `deadbeef` | Rails secret (change for production) |
| `DB_PASSWORD` | `sandcastle` | PostgreSQL password |
| `DOCKER_GID` | `0` | Docker socket group ID |

### Development (`docker-compose.dev.yml`)

Same as production-like, plus:

| Variable | Default | Description |
|----------|---------|-------------|
| `RAILS_ENV` | `development` | Rails environment |
| `SANDCASTLE_HOST` | `localhost` | Host for URLs |

## Architecture

### Services

- **traefik** — Reverse proxy (ports 8080:80, 8443:443)
- **postgres** — PostgreSQL 18 database
- **web** — Rails app (Puma server on port 80 inside container)
- **worker** — Solid Queue background worker
- **migrate** — One-shot migration runner (runs on startup)
- **init-data** — One-shot data directory initializer
- **init-traefik** — One-shot Traefik config initializer

### Networks

- **sandcastle-web** — External bridge network (must be created manually)
- **default** — Default compose network for internal communication

### Volumes

| Volume | Purpose |
|--------|---------|
| `pgdata` | PostgreSQL data |
| `sandcastle-data` | User homes, sandbox volumes, Tailscale state |
| `traefik-data` | Traefik config and certificates |
| `bundle-data` | Ruby gems (dev mode only) |
| `node-modules` | Node packages (dev mode only) |

### Ports

- **8080** — HTTP (Traefik web entrypoint)
- **8443** — HTTPS (Traefik websecure entrypoint)
- **2201-2299** — SSH ports for sandboxes (mapped to host)

## Troubleshooting

### Containers Won't Start

```bash
# Check container logs
docker compose -f docker-compose.local.yml logs

# Inspect failed container
docker inspect sandcastle-web

# Check for port conflicts
lsof -i :8080
lsof -i :8443
```

### Database Connection Errors

```bash
# Check if postgres is healthy
docker inspect sandcastle_postgres_1 | grep Health -A 10

# Check database logs
docker logs sandcastle_postgres_1

# Try connecting manually
docker exec -it sandcastle_postgres_1 psql -U sandcastle -d sandcastle_production
```

### Docker Socket Permission Denied

The web/worker containers need access to `/var/run/docker.sock`. On macOS this usually works, on Linux you may need to set `DOCKER_GID`:

```bash
# Find Docker socket GID
stat -c '%g' /var/run/docker.sock  # Linux
stat -f '%g' /var/run/docker.sock  # macOS

# Set it in your environment
export DOCKER_GID=988
mise run deploy:local
```

### Traefik Not Routing

```bash
# Check if sandcastle-web network exists
docker network ls | grep sandcastle-web

# Create it if missing
docker network create sandcastle-web

# Restart Traefik
docker compose -f docker-compose.local.yml restart traefik

# Check Traefik logs
docker logs sandcastle_traefik_1
```

### Sandbox Containers Won't Start

Sandboxes require the Sysbox runtime:

```bash
# Check if Sysbox is installed
docker info | grep -i sysbox

# List available runtimes
docker info | grep -A 5 Runtimes

# Check Sysbox status (Linux)
systemctl status sysbox
```

### Reset Everything

If things are completely broken:

```bash
# Stop everything
mise run deploy:local:down
mise run deploy:dev:down

# Remove all Sandcastle containers
docker ps -a | grep -E "sandcastle|sc-wetty|sc-ts" | awk '{print $1}' | xargs -r docker rm -f

# Remove all volumes
docker volume ls | grep sandcastle | awk '{print $2}' | xargs -r docker volume rm

# Remove network
docker network rm sandcastle-web

# Recreate network
docker network create sandcastle-web

# Start fresh
mise run deploy:local:reset
```

## Default Admin Credentials

The migrate service creates a default admin user (see `docker-compose.local.yml` lines 169-172):

- **Username:** `thies`
- **Email:** `thieso@gmail.com`
- **Password:** `tubu`
- **SSH Key:** (set in compose file)

These are defined in the `SANDCASTLE_ADMIN_*` environment variables.

## Development Workflow

When using `mise run deploy:dev`:

1. Source code is mounted at `/rails` in the container
2. Changes to `.rb`, `.erb`, `.css` files reload automatically
3. Tailwind CSS recompiles on save
4. Gems are persisted in a volume (faster than bind mount)
5. Database data persists between restarts

**Tips:**
- Edit files on the host, changes reflect immediately in the container
- If you add a gem, rebuild: `docker compose -f docker-compose.dev.yml up --build`
- Database migrations: `docker exec -it sandcastle-web ./bin/rails db:migrate`
- Run tests: `docker exec -it sandcastle-web ./bin/rails test`

## CLI Development

The Go CLI is in `vendor/sandcastle-cli/`. It's not part of the Docker Compose setup:

```bash
cd vendor/sandcastle-cli

# Build
make build

# Test against local Sandcastle
export SANDCASTLE_API_URL=https://localhost:8443
export SANDCASTLE_API_TOKEN=sc_...  # Get from UI
./sandcastle list
```

## Useful Docker Commands

```bash
# Restart a single service
docker compose -f docker-compose.local.yml restart web

# Rebuild a single service
docker compose -f docker-compose.local.yml up --build web

# Execute a command in a container
docker exec -it sandcastle-web bash

# Copy files from container
docker cp sandcastle-web:/rails/log/production.log ./

# Copy files to container
docker cp ./config.yml sandcastle-web:/rails/config/

# Inspect container details
docker inspect sandcastle-web

# View resource usage
docker stats

# Prune unused images/volumes (be careful!)
docker system prune -a
```

## File Locations

### On Host

- **Compose files:** `docker-compose.{local,dev}.yml`
- **Mise config:** `mise.toml`
- **Source code:** `.` (mounted in dev mode)

### In Container

- **Rails root:** `/rails`
- **Data directory:** `/data`
  - User homes: `/data/users/{username}/home`
  - Sandbox volumes: `/data/sandboxes/{sandbox_name}/vol`
  - Tailscale state: `/data/users/{username}/tailscale`
  - WeTTY keys: `/data/wetty/{full_name}/`
- **Traefik config:** `/data/traefik/dynamic/`
- **Database:** `/var/lib/postgresql` (in postgres container)

## Accessing Services

| Service | URL | Notes |
|---------|-----|-------|
| Web UI (HTTPS) | https://sandcastle.local:8443 | Recommended, supports terminals |
| Web UI (HTTP) | http://sandcastle.local:8080 | No TLS |
| PostgreSQL | `localhost:5432` | Not exposed by default |
| Traefik | — | No dashboard exposed |

Add to `/etc/hosts` for `sandcastle.local`:
```
127.0.0.1 sandcastle.local
```

For localhost, use `https://localhost:8443`.
