# Sandcastle

Self-hosted shared Docker sandbox platform. Each user gets isolated [Sysbox](https://github.com/nestybox/sysbox) containers with SSH access and a full Docker daemon inside.

## Architecture

```mermaid
flowchart TB
    CLI["Go CLI\n(sandcastle)"] --> API["Rails API\n(Bearer token)"]
    Browser["Web Dashboard"] --> Web["Rails Web\n(Session auth)"]
    API --> SM["SandboxManager"]
    Web --> SM
    Web --> TM["TerminalManager"]
    SM --> Docker["Docker + Sysbox"]
    Docker --> S1["Sandbox 1\n(SSH + DinD)"]
    Docker --> S2["Sandbox 2\n(SSH + DinD)"]
    TM --> Traefik["Traefik\n(reverse proxy)"]
    TM --> WeTTY["WeTTY\nSidecars"]
    WeTTY -.->|SSH + tmux| S1
    SM --> TS["TailscaleManager"]
    TS --> TSC["Tailscale\nSidecars"]
```

- **Backend:** Rails 8.1 (Ruby 4.0), PostgreSQL, Solid Queue/Cache/Cable
- **CLI:** Go + Cobra (`vendor/sandcastle-cli/`)
- **Containers:** Docker + Sysbox (`sysbox-runc`) for sandboxes
- **Web terminal:** [WeTTY](https://github.com/butlerx/wetty) sidecar containers with Traefik routing
- **Auth:** Session-based (web) + API tokens (`sc_` prefix, bcrypt)
- **Sandbox image:** Ubuntu 24.04 with Docker-in-Docker, SSH, dev tools

## Getting Started

### Prerequisites

- Ruby 4.0
- Docker with [Sysbox](https://github.com/nestybox/sysbox) runtime
- Go 1.22+ (for CLI development)

### Development

```bash
bin/dev              # Start dev server (web + Tailwind watcher)
bin/rails test       # Run tests
bin/rubocop          # Lint
bin/brakeman         # Security scan
bin/ci               # Full CI suite
```

### CLI

```bash
cd vendor/sandcastle-cli && make build
sandcastle create my-dev --home --data
sandcastle list
sandcastle ssh my-dev
sandcastle destroy my-dev
```

## Deployment

See [DEPLOY.md](DEPLOY.md) for registry setup, CI/CD pipeline, and deploy workflows.

## Acknowledgments

- [WeTTY](https://github.com/butlerx/wetty) by Cian Butler and contributors — the browser-based terminal emulator powering Sandcastle's web terminal feature
- [Sysbox](https://github.com/nestybox/sysbox) by Nestybox — the container runtime enabling secure Docker-in-Docker sandboxes
- [Traefik](https://github.com/traefik/traefik) — reverse proxy handling TLS termination and dynamic routing

## License

MIT
