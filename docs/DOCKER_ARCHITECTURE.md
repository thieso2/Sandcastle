# Sandcastle Docker Architecture (Reference for an Incus Port)

This document captures the architecture Sandcastle currently runs on Docker + Sysbox, in enough detail to reproduce it on **Incus / LXD**. Every concept here maps cleanly to a primitive Incus already has: containers, profiles, projects, bridge networks, disk devices, proxy devices.

Source of truth: `app/services/{sandbox_manager,network_manager,tailscale_manager,dns_manager,route_manager,sandbox_mount_builder}.rb` and `docs/NETWORKING.md`.

---

## 1. Container runtime

| Concern | Docker (current) | Incus mapping |
|---|---|---|
| Engine | **Isolated Docker daemon "dockyard"** (`sc_docker`, separate from host's system Docker), socket at `/sandcastle/dockyard/docker.sock` | `incusd` (one engine per host, but use a **dedicated Incus project** `sandcastle` to isolate) |
| Runtime | `sysbox-runc` (rootless-ish, gives each container its own kernel-like view so Docker-in-Docker works) | Incus **system containers** are already user-namespaced and run their own systemd / dockerd. Use `security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true` to allow nested Docker. |
| Image | `ghcr.io/thieso2/sandcastle-sandbox:latest` — Ubuntu 24.04 + dockerd + sshd + dev tools | Build an Incus image from the same Ubuntu base; install dockerd + openssh-server. Push to an Incus image server or `incus image import`. |
| Daemon iptables | `--iptables=false` — Sandcastle owns iptables via a systemd unit (`sc_docker.service`) that installs NAT + FORWARD rules for the whole /16 at boot | Incus bridges manage their own nftables rules. Trust them; do not hand-roll. |

**Key flag for Incus sandboxes (equivalent of Sysbox):**
```
security.nesting=true
security.privileged=false
linux.kernel_modules=overlay,nf_nat,xt_conntrack,br_netfilter
```

---

## 2. Networking

### 2.1 The single knob: `SANDCASTLE_PRIVATE_NET`

One RFC 1918 `/16` (default `10.89.0.0/16`) carves out **all** Sandcastle networks. Three values derive from it (all overridable):

| Var | Default | Purpose |
|---|---|---|
| `SANDCASTLE_PRIVATE_NET` | `10.89.0.0/16` | The whole pool |
| `DOCKYARD_BRIDGE_CIDR` | `10.89.0.1/24` | Gateway IP of the default bridge `sc_docker0` |
| `DOCKYARD_FIXED_CIDR` | `10.89.0.0/24` | Address range Docker assigns on the default bridge |
| `DOCKYARD_POOL_BASE` | same as `PRIVATE_NET` | Pool from which user-defined networks get `/24`s |
| `DOCKYARD_POOL_SIZE` | `24` | Prefix length of each allocated subnet |

The Rails app reads `DOCKYARD_POOL_BASE` to pick `/24`s for per-user networks (`TailscaleManager#subnet_for`, `NetworkManager#generate_subnet`). **If this env var is wrong, sidecars get IPs outside the host MASQUERADE rule and silently lose internet** — see `app/services/tailscale_manager.rb:502`.

**Host-level iptables (set by `sc_docker.service`, not by dockerd):**
```
iptables -t nat -A POSTROUTING -s 10.89.0.0/16 ! -o sc_docker0 -j MASQUERADE
iptables -A FORWARD -s 10.89.0.0/16 -j ACCEPT
iptables -A FORWARD -d 10.89.0.0/16 -j ACCEPT
```

### 2.2 Networks at runtime

Three classes of network, all carved from the `/16`:

| Network | Created by | Purpose | Address |
|---|---|---|---|
| `sc_docker0` (default bridge) | Daemon at startup, `--bip=…` | Fallback bridge; rarely used directly | `10.89.0.0/24` |
| `sandcastle-web` | Installer | "Service bus": Rails ↔ Traefik ↔ WeTTY ↔ noVNC ↔ sandbox. Auto-allocated from pool. | first free `/24` from pool |
| `sc-net-{user}` | `NetworkManager#ensure_user_network` (advisory-lock serialised) | **Per-user tenant network**, used to isolate that user's sandboxes from other users' sandboxes | random `/24` from pool, persisted in `users.network_subnet` |
| `sc-ts-net-{user}` | `TailscaleManager#create_and_start_sidecar` | **Per-user Tailscale bridge** that the sidecar advertises as a subnet route | `oct1.oct2.(1 + user_id % 255).0/24` (deterministic), persisted in `users.tailscale_subnet` |

Every sandbox is connected to:
1. `sandcastle-web` (so Traefik/WeTTY can reach it)
2. `sc-net-{user}` (tenant isolation)
3. `sc-ts-net-{user}` (only if Tailscale auto-connect is on for that user)

**Incus mapping:** one Incus managed bridge per equivalent. Use `incus network create scN-…` with `ipv4.address`, `ipv4.nat=true`, `ipv4.dhcp=false`. Subnet allocation logic stays in the Rails app — Incus doesn't auto-allocate from a pool the way Docker does, so you generate the `/24` yourself (same code path).

---

## 3. Tailscale per-user sidecars

Each user gets their **own** Tailscale node joining **their** tailnet. Not a shared Sandcastle tailnet — the user controls auth.

### 3.1 Sidecar container

- Image: `tailscale/tailscale:latest`
- Name: `sc-ts-{username}`
- Hostname: `sc-{slugified SANDCASTLE_NAME}` (one machine name per host, distinguished by user)
- Network: `sc-ts-net-{user}` (only)
- Runtime: **plain `runc`** (Sysbox does not expose the netfilter/SNAT bits needed for subnet routing — see `tailscale_manager.rb:584`)
- Required:
  - `cap_add: NET_ADMIN, SYS_MODULE`
  - device `/dev/net/tun`
  - bind `/lib/modules:/lib/modules:ro`
  - sysctl `net.ipv4.ip_forward=1`
  - bind state dir: `/data/users/{user}/tailscale:/var/lib/tailscale`
- Fallback: `SANDCASTLE_TAILSCALE_USERSPACE=1` → userspace networking, no `/dev/net/tun`, no `cap_add`. Subnet routing degraded.

### 3.2 Two auth flows

| Flow | Entry | Mechanism |
|---|---|---|
| Auth-key | Default `containerboot` | `TS_AUTHKEY` env; `tailscale up --advertise-routes={subnet} --accept-routes` runs once and exits-on-SIGTERM with `tailscale logout` (which **expires the node key** — bad for restores). |
| Interactive | Override entrypoint to `tailscaled --state=…` directly | Rails `exec`s `tailscale up --reset --advertise-routes={subnet} --timeout=10s` in the container, polls `tailscale status --json` for `BackendState`, harvests `AuthURL` and shows it to the user. |
| Restore-from-state | Override entrypoint to raw `tailscaled` (no `--reset`) | Re-uses persisted `tailscaled.state` from `/data/users/{user}/tailscale/` after reinstall; re-runs `tailscale up` to re-advertise routes (subnet may have changed across reinstalls). |

The **user `tailscale_state` field** progresses: `disabled → pending → enabled`. The Rails UI polls `/tailscale/check_login` every 3 s during `pending`.

### 3.3 What the sidecar advertises

`--advertise-routes={sc-ts-net-{user} CIDR}` — so anything else on the user's tailnet can reach the sandboxes by their **container IP on that bridge**. The sandbox container's Tailscale-network IP is recorded in `/etc/sandcastle/runtime` (see `write_sandbox_runtime_metadata`, line 327) so the in-sandbox tooling can self-locate.

### 3.4 Auto-connect

User flag `tailscale_auto_connect=true` ⇒ `SandboxManager#create` connects new sandboxes to the user's TS bridge automatically. Reconcile loop is `ContainerSyncJob` (every 5 min).

**Incus mapping:** unchanged. Run the same `tailscale/tailscale` container inside an Incus container (use Incus OCI support: `incus launch docker:tailscale/tailscale` — or just keep Docker running this single image inside an Incus container if you want zero refactor). Either way, the network it joins is `sc-ts-net-{user}` (an Incus managed bridge) and the same `--advertise-routes` value applies.

---

## 4. DNS (CoreDNS per-user resolver)

Per-user CoreDNS sidecar so the user's tailnet can resolve sandbox names via Tailscale's **per-user MagicDNS override**.

### 4.1 Container

- Image: `coredns/coredns:latest`
- Name: `sc-dns-{username}`
- Network: `sc-ts-net-{user}` (so the sidecar can use it; the sidecar's IP is the DNS server advertised to the tailnet)
- Bind: `/data/users/{user}/dns:/data:ro` (Corefile + zone file + hosts file)
- Cmd: `-conf /data/Corefile`
- Only spawned when Tailscale is enabled (`reconcile_all` filters on `tailscale_state: enabled`).

### 4.2 Naming scheme

FQDN per sandbox: `{sandbox-name}.{project-name | "sandboxes"}.{instance-suffix}`

- `instance-suffix` = slugified `SANDCASTLE_NAME` (or hostname)
- All three components forced through `dns_label()` — lowercase, `_` → `-`, `[^a-z0-9-]+` → `-`, must match `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`, ≤63 chars.

Example: sandbox `foo` in project `acme` on instance `hz1` → `foo.acme.hz1`.

Aliases:
- `kind=sub` → `{value}.{fqdn}` (sandbox owner adds `dev` → `dev.foo.acme.hz1`)
- `kind=fqdn` → absolute, e.g. `www.heise.de` (literal)

### 4.3 Corefile (generated)

```
{suffix}:53 {
  reload 2s
  # one template block per record:
  template IN A {suffix} {
    match ^([^.]+\.)?{fqdn}\.$
    answer "{{ .Name }} 15 IN A {ip}"
    fallthrough
  }
  # extra CNAME block to handle macOS search-domain double-suffix (e.g. foo.acme.hz1.hz1)
  file /data/db.{suffix} {suffix}
  errors
  log
}
```

Plus a zone file (`db.{suffix}`) with hourly serial, 15 s TTL, A + `*.A` records. Plus a `hosts` file the CLI consumes locally.

### 4.4 Wiring into the tailnet

The user configures their tailnet **split DNS** so that `{suffix}` resolves via the sidecar's IP. The sidecar IP comes from `Docker::Container#inspect → NetworkSettings.Networks[sc-ts-net-{user}].IPAddress`. Because the sidecar advertises the whole `/24`, anything on the user's tailnet reaches the resolver at that IP through the Tailscale sidecar.

**Incus mapping:** one-to-one. Same CoreDNS container on the same per-user bridge.

---

## 5. HTTP routing (Traefik)

Single Traefik container `sandcastle-traefik` on `sandcastle-web`. Dynamic config files in `/data/traefik/dynamic/*.yml` (file provider, hot-reload).

| File | Owner | Purpose |
|---|---|---|
| `sandbox-{id}.yml` | `RouteManager#write_config` | Per-sandbox HTTP/TCP routes (user-defined `domain → container:port`) |
| `terminal-{id}.yml` | `TerminalManager#prepare_traefik_config` | WeTTY terminal route + forwardAuth middleware → Rails `/terminal/auth` |
| `novnc-{id}.yml` | `VncManager#prepare_traefik_config` | noVNC route + forwardAuth |
| `rails.yml` | `RouteManager#write_rails_config` | Main app host(s) |

**TCP ports** (`mode: "tcp"`) come out of a fixed range `SANDCASTLE_TCP_PORT_MIN..MAX` (default 3000-3099). Traefik gets a new entrypoint per allocated port (`ensure_tcp_entrypoint`).

**Auth on terminal/VNC:** Traefik forwardAuth → `http://sandcastle-web:80/terminal/auth` with `X-Forwarded-Uri`. Rails validates session cookie + sandbox ownership, returns 200/302/401.

**Incus mapping:** keep Traefik. The only Docker-specific bit is that Traefik joins the `sandcastle-web` bridge — that's a single proxy device in Incus or a container on the same managed bridge. Traefik discovers backends by **hostname**, not Docker labels (it's the file provider, not the docker provider), so nothing else changes.

---

## 6. Storage: shared home, per-project persisted, snapshot mode

Source: `app/services/sandbox_mount_builder.rb`.

### 6.1 Directory layout under `/data` (host)

```
/data/
├─ users/
│  └─ {username}/
│     ├─ home/                 ← shared $HOME (all sandboxes for this user, by default)
│     │  └─ {home_path}/       ← optional sub-home (per-sandbox scoped home)
│     ├─ data/
│     │  └─ {data_path}/       ← per-project persisted volume → /persisted in container
│     ├─ persisted/
│     │  └─ {pp.path}/         ← per-user persisted dotdirs (~/.claude, ~/.codex…)
│     ├─ tailscale/             ← tailscaled.state (root-owned, 0700)
│     └─ dns/                   ← Corefile, zone file, hosts
├─ sandbox_mounts/
│  └─ {sandbox_id}/
│     ├─ base/{home|data|persisted/…}/  ← snapshot base (read-only origin)
│     └─ work/{home|data|persisted/…}/  ← snapshot writable layer
├─ traefik/dynamic/*.yml
└─ wetty/{user}/                ← per-open SSH keypair for WeTTY sidecar
```

### 6.2 Mount rules (per sandbox)

For each sandbox, `SandboxMountBuilder#direct_mount_attributes` emits the following bind mounts:

| When | Host source | Container target | Notes |
|---|---|---|---|
| Always (if `mount_home` or `home_path` set) | `/data/users/{u}/home[/home_path]` | `/home/{u}` | **Shared across all of that user's sandboxes by default.** Set `home_path` to scope to a subdir. |
| If `data_path` set | `/data/users/{u}/data/{data_path}` | `/persisted` | **Per-project persisted volume.** This is the "per-project" knob. |
| For each `user.persisted_paths` (when full home not mounted) | `/data/users/{u}/persisted/{pp.path}` | `/home/{u}/{pp.path}` | Cherry-pick dotdirs (e.g. `~/.claude`) so sandboxes share creds but not full $HOME. |

**Shared-home implications:**
- Multiple running sandboxes write the same `~/.bashrc`, `~/.ssh/authorized_keys`, etc. The sandbox entrypoint **appends** SSH keys (not overwrites) precisely because of this.
- BTRFS subvolumes for `/data/users/{u}` give per-user CoW + snapshot capability (`BtrfsHelper`).

### 6.3 Storage modes

`sandbox.storage_mode`:
- `"direct"` (default) — bind mounts described above. Writes go to the real host paths immediately.
- `"snapshot"` — `SandboxMountBuilder#snapshot_mount_attributes` redirects each mount through a per-sandbox `work/` overlay rooted at `/data/sandbox_mounts/{sandbox_id}/`. `base/` is populated at create from the real home/data; `work/` is the writable layer the sandbox sees. Snapshot/restore manipulates these directories. See `docs/SNAPSHOTS.md`.

### 6.4 Incus mapping

| Sandcastle Docker | Incus equivalent |
|---|---|
| Bind mount (host path → container path) | `disk` device with `source=...`, `path=...`, `shift=true` (for UID remap) |
| BTRFS subvolume per user | Incus storage pool with `driver=btrfs`, **storage volumes** per user (`incus storage volume create`) — gives the same CoW + snapshot semantics natively |
| Snapshot storage mode | Incus `volume snapshot` (native) instead of the manual `base/`+`work/` overlay |
| Shared home across sandboxes | A single **custom storage volume** `users/{u}/home` attached to N containers. Incus supports concurrent attachment of custom volumes. |
| Per-project persisted | One custom volume per `data_path`, attached only to the relevant sandbox(es). |

If you go full-Incus, the snapshot mode collapses from "manual rsync into `base/work` dirs" to native volume snapshots — that's a meaningful simplification.

---

## 7. Container env / labels / runtime hints

Every sandbox container gets:

- **Hostname**: the DnsManager FQDN (e.g. `foo.acme.hz1`) so `hostname` inside matches DNS.
- **Labels**: `sandcastle.sandbox=true` (used by `ContainerSyncJob` to find orphans). Per-user networks have `sandcastle.owner={username}` (refuse to delete without it — `NetworkManager#cleanup_user_network`).
- **DNS servers** (`HostConfig.Dns`): from `SANDCASTLE_DOCKER_DNS` env (comma-separated). Needed where the host blocks outbound UDP/53 (Hetzner). The sandbox's inner dockerd inherits these, so nested `docker run` containers also get them.
- **RestartPolicy**: `unless-stopped`.
- **NetworkMode**: `sandcastle-web` (initially; `sc-net-{user}` and `sc-ts-net-{user}` attached after start via separate `network.connect`).
- **/etc/sandcastle/runtime** written via `exec` post-start with `SC_TAILSCALE`, `SC_TAILSCALE_IP`, `SC_DNS`, `SC_PROJECT`, `SC_PROJECT_PATH` — read by in-sandbox tooling and the user's shell prompt.

---

## 8. Reconciliation

`ContainerSyncJob` runs every 5 min (Solid Queue, `config/recurring.yml`):

1. Reads all `Sandbox` rows where `status != destroyed`.
2. Compares to actual `docker ps` output (filter `label=sandcastle.sandbox=true`).
3. Marks DB rows as `running`/`stopped`/`destroyed` to match reality.
4. For Tailscale-enabled users, re-checks sidecar health (`tailscale status --json`).
5. Calls `NetworkManager#ensure_sandbox_connected` to reconnect to `sc-net-{user}` if missing.
6. `DnsManager#reconcile_all` republishes Corefile/zone.

**Incus mapping:** swap `docker ps` for `incus list -f json --project sandcastle`. Everything else is unchanged.

---

## 9. Minimum viable Incus port — checklist

A direct translation, no architectural changes:

1. **Project**: `incus project create sandcastle` with `features.networks=true, features.images=true, features.profiles=true, features.storage.volumes=true`.
2. **Storage pool**: `incus storage create scpool btrfs source=/data` (or `dir` if not BTRFS).
3. **Profile `sandcastle-sandbox`**:
   - `security.nesting=true`
   - `security.syscalls.intercept.mknod=true`
   - `security.syscalls.intercept.setxattr=true`
   - `linux.kernel_modules=overlay,nf_nat,br_netfilter`
   - default root disk pointed at `scpool`
4. **Networks** (all with `ipv4.nat=true`):
   - `sc-web` — `10.89.1.0/24`
   - `sc-net-{u}` — random `/24` from `10.89.0.0/16`
   - `sc-ts-net-{u}` — deterministic `/24` (same formula as today)
5. **Sandbox image**: rebuild current `images/sandbox/Dockerfile` as an Incus image (same Ubuntu 24.04 + dockerd inside + sshd). `incus image import`.
6. **Tailscale sidecar**: keep as a Docker container (simplest) **or** wrap as an Incus container running tailscaled directly. Either way, attach to `sc-ts-net-{u}`. Same `--advertise-routes`.
7. **CoreDNS sidecar**: same — Incus container or Docker container on `sc-ts-net-{u}`.
8. **Traefik**: same. On `sc-web`. File provider unchanged.
9. **Volumes**: create custom volume `users-{u}-home` once per user; attach to N sandbox containers via profile or per-instance `disk` device. Per-project: one volume per `data_path`.
10. **Replace `docker-api` calls** in `SandboxManager`/`NetworkManager`/`TailscaleManager`/`DnsManager`/`RouteManager` with `incus` CLI or REST API (`/1.0/instances`, `/1.0/networks`, `/1.0/storage-pools/.../volumes`).

The data model in Rails (users, sandboxes, networks, subnets, tailscale state, mounts) doesn't change. Only the bottom service layer is rewritten.

---

## 10. Things to **not** carry over from the Docker port

- `--iptables=false` plus a systemd unit owning iptables — Incus manages nftables for its bridges. Delete the unit.
- The `base/work/` snapshot directories — use Incus storage volume snapshots.
- `BtrfsHelper`'s `sudo btrfs subvolume create` shelling out — use `incus storage volume create` (it does the same thing under the hood).
- The `docker_chown` permission-repair dance via short-lived busybox containers — Incus `shift=true` on disk devices handles UID mapping properly.
- `containerboot`'s `tailscale logout`-on-SIGTERM gotcha — only relevant if you keep the Docker Tailscale sidecar; mention it in the runbook if so.
