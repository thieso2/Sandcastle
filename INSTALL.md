# Installation

## Prerequisites

**Server** (tested on Ubuntu 24.04):
- A Linux host with root access
- At least 4 GB RAM, 100 GB disk

**Dev machine:**
- SSH access to the server
- Ruby 4.0+ and Bundler (for Kamal)
- Go 1.25+ (for CLI development)

## Server setup

The `bin/setup-server` script handles everything from your dev machine:

```bash
bin/setup-server user@your-server-ip
```

This installs and configures:
- Docker (for Kamal deployment of the Rails app)
- Incus + ZFS (for sandbox containers)
- Caddy (reverse proxy with automatic HTTPS)
- UFW firewall (ports 22, 80, 443, 2201-2299)
- Sandbox and Tailscale Incus images
- The `sandcastle` Incus profile

The script is idempotent — safe to re-run on an already-provisioned server.

### What gets installed where

```
/data/
├── users/{name}/
│   ├── home/          # Persistent user home directories
│   └── tailscale/     # Tailscale sidecar state
└── sandboxes/{name}/
    └── vol/           # Persistent workspace volumes
```

## Deploy the Rails app

### 1. Configure Kamal

Edit `config/deploy.yml` with your server IP, registry, and SSH user.

Set the required secrets in `.kamal/secrets`:

```bash
SECRET_KEY_BASE=<rails secret>
RAILS_MASTER_KEY=<from config/master.key>
KAMAL_REGISTRY_PASSWORD=<registry password>
```

### 2. Deploy

```bash
kamal setup    # First deploy (provisions server-side Docker resources)
kamal deploy   # Subsequent deploys
```

### 3. Initialize the database

```bash
kamal app exec 'bin/rails db:prepare'
```

This runs migrations and seeds the admin user.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_KEY_BASE` | — | Rails secret (required) |
| `RAILS_MASTER_KEY` | — | Decrypts `credentials.yml.enc` |
| `SANDCASTLE_HOST` | `sandcastle.rocks` | Public hostname (used by Caddy) |
| `SANDCASTLE_DATA_DIR` | `/data` | Root for user/sandbox persistent data |
| `INCUS_SOCKET` | `/var/lib/incus/unix.socket` | Path to Incus daemon socket |

## Rebuilding images

If you update the sandbox or Tailscale image definitions, re-run `bin/setup-server` to rebuild them on the server. The bootstrap script will overwrite existing images.

Alternatively, build directly on the server:

```bash
sudo bash images/sandbox/build-image.sh
sudo bash images/tailscale/build-image.sh
```

## CLI installation

Build the Go CLI and distribute the binary to users:

```bash
cd vendor/sandcastle-cli
make build    # produces ./sandcastle
```

Users configure it with:

```bash
sandcastle config set server https://your-server
sandcastle login
```

## Firewall rules

The bootstrap script configures UFW:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | Host SSH |
| 80 | TCP | HTTP (Caddy redirect) |
| 443 | TCP | HTTPS (Caddy) |
| 2201-2299 | TCP | Sandbox SSH access |

## Troubleshooting

### Check Incus status

```bash
sudo incus list                    # Running instances
sudo incus image list              # Available images
sudo incus profile show sandcastle # Sandbox profile
```

### Check the Rails app

```bash
kamal app logs          # Application logs
kamal app exec 'bin/rails console'  # Rails console
```

### Re-run server setup

```bash
bin/setup-server user@your-server-ip
# Safe to re-run — all steps are idempotent
```
