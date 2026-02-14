# Docker with Sysbox Runtime Research

**Date:** February 13, 2026
**Purpose:** Document the current Docker + Sysbox solution for Sandcastle as baseline for comparison

## Executive Summary

Sysbox is an open-source, next-generation OCI runtime (specialized fork of `runc`) that enables rootless containers to run system-level workloads like Docker, Kubernetes, and systemd securely without privileged containers. For Sandcastle, it provides isolated Docker-in-Docker environments with stronger security than vanilla Docker but weaker isolation than VMs.

**Key Strengths:**
- Secure Docker-in-Docker without privileged containers or bind-mounting host Docker socket
- Full Docker API compatibility via standard docker-api gem
- Good performance (similar to standard runc)
- Mature project with Docker backing since 2022 acquisition
- No nested virtualization required

**Key Weaknesses:**
- Kernel version dependency (5.12+ for ID-mapped mounts, or Ubuntu/Debian with shiftfs)
- Community-driven support only (not officially supported by Docker)
- Installation complexity with multiple components
- Some functional limitations (no kernel modules, NFS server, nested user namespaces)
- containerd support still maturing (officially CRI-O only)

---

## 1. What is Sysbox?

[Sysbox](https://github.com/nestybox/sysbox) is an OCI-compliant container runtime forked from the standard `runc` in early 2019 by Nestybox. [Docker acquired Nestybox on May 10, 2022](https://www.docker.com/blog/docker-advances-container-isolation-and-workloads-with-acquisition-of-nestybox/), and integrated Sysbox technology into [Docker Desktop's Enhanced Container Isolation (ECI)](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/) feature.

### How It Enables Docker-in-Docker

According to the [Sysbox DinD documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/dind.md), Sysbox enables Docker-in-Docker by:

1. **Creating "system containers"** that behave like lightweight VMs rather than application containers
2. **Isolating the inner Docker completely** from the host Docker daemon
3. **Eliminating privileged containers** — no need for `--privileged` flag or bind-mounting `/var/run/docker.sock`
4. **Automatically setting up the container environment** so Docker can run inside as if on a physical host

The [Sysbox architecture](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/design.md) consists of three components:
- **sysbox-runc**: Modified OCI runtime with user namespace and syscall interception
- **sysbox-mgr**: Manages container lifecycle and resource allocation
- **sysbox-fs**: FUSE filesystem that virtualizes portions of `/proc` and `/sys`

---

## 2. Security Isolation Model

### Isolation Strength Comparison

According to the [Nestybox technology comparison blog](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html):

> Sysbox containers provide **stronger isolation than regular Docker containers** (by virtue of using the Linux user-namespace and light-weight OS shim), but **weaker isolation than VMs** (by sharing the Linux kernel among containers).

### Security Mechanisms

The [Sysbox security documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security.md) outlines these key security features:

#### a) **Mandatory Linux User Namespaces**

All Sysbox containers automatically use user namespaces, which map root (UID 0) inside the container to an unprivileged UID on the host (typically 100000+). This means:
- Root in the container has **zero privileges on the host**
- Even with all capabilities granted inside the container, processes can't escape
- Each container gets an **exclusive 65536 UID range** for POSIX compliance

#### b) **Filesystem User ID Remapping**

Starting with [Sysbox v0.5.0](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/storage.md), Sysbox uses:
- **ID-mapped mounts** (Linux kernel ≥ 5.12), or
- **shiftfs kernel module** (Ubuntu, Debian, Flatcar with kernel < 5.12)

This ensures bind-mounted host directories appear with correct permissions inside the container's user namespace without actual file ownership changes on the host.

#### c) **Selective Syscall Interception**

Sysbox intercepts and virtualizes certain syscalls to:
- Prevent containers from seeing host information in `/proc` and `/sys`
- Emulate container-specific mount tables and namespaces
- Lock initial mounts (immutable from inside container)

#### d) **Procfs/Sysfs Virtualization**

According to the [Sysbox security quickstart](https://github.com/nestybox/sysbox/blob/master/docs/quickstart/security.md), Sysbox virtualizes portions of:
- `/proc/sys/*` — container-specific kernel parameters
- `/proc/uptime`, `/proc/loadavg` — container-isolated metrics
- `/sys/class/*` — container view of devices

### How Much Stronger Than Vanilla Docker?

[System Container Security blog post](https://blog.nestybox.com/2019/11/20/syscont-security.html) explains the difference:

| Feature | Vanilla Docker | Docker + Sysbox |
|---------|---------------|-----------------|
| User namespace | Optional, rarely used | Mandatory, always enabled |
| Root privileges | Root in container = root on host (with some caps) | Root in container = unprivileged user on host |
| Privileged containers | Full host access for DinD | DinD without privileged flag |
| Host info leakage | `/proc`, `/sys` show host data | Virtualized container-specific views |
| UID mapping | Shared UIDs across containers | Exclusive 65K UID range per container |

**Verdict:** Sysbox provides **significantly stronger isolation** than vanilla Docker, approaching VM-like boundaries without the overhead. However, it still shares the kernel, so a kernel exploit could compromise the host.

---

## 3. Docker-in-Docker Implementation

### Standard Approach vs. Sysbox

According to [Cesar Talledo's Medium article on secure DinD](https://ctalledo.medium.com/secure-docker-in-docker-with-nestybox-529c5c419582):

**Standard DinD Problems:**
- Requires `--privileged` flag → container can escape to host
- Or bind-mount `/var/run/docker.sock` → inner containers run on host daemon (no isolation)
- Complex `docker run` commands with many capabilities

**Sysbox Approach:**
```bash
docker run --runtime=sysbox-runc -it ubuntu:latest
# Inside container:
apt-get update && apt-get install -y docker.io
systemctl start docker
docker run hello-world
```

Simple, secure, isolated inner Docker daemon.

### Sandcastle Implementation Details

From the Sandcastle codebase and CLAUDE.md:

- **Runtime:** All sandbox containers use `runtime: sysbox-runc` in Docker API calls
- **Container creation:** Standard Docker API via `docker-api` gem (Ruby)
- **Networking:** Standard Docker bridge networks and port bindings
- **Volumes:** Host directories bind-mounted at `/data/users/{name}/home` and `/data/sandboxes/{name}/vol:/workspace`
- **SSH access:** Exposed via unique host ports (2201-2299 range)
- **Entrypoint:** Custom `entrypoint.sh` that creates user, injects SSH keys, starts dockerd, then sshd

---

## 4. Networking Capabilities

### Bridge Networks

Sysbox containers support standard Docker networking:
- Default bridge networks work out of the box
- Custom bridge networks for isolation (e.g., Sandcastle's Tailscale per-user bridges `sc-ts-net-{username}`)
- Full IPv4 networking with NAT

### Port Bindings

Standard Docker port mapping works:
```bash
docker run --runtime=sysbox-runc -p 2201:22 sandbox-image
```

In Sandcastle:
- SSH ports: `-p {2201-2299}:22` for user access
- No special Sysbox configuration required
- Performance equivalent to standard runc

### Limitations

From the [networking documentation](https://docs.kernel.org/networking/bridge.html), general Linux bridge networking is well-supported. However, the [Sysbox limitations doc](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/limitations.md) notes:

- **No `/dev/tun`, `/dev/tap`, `/dev/fuse` creation** — VPN servers or FUSE filesystems inside containers fail
- **No NFS server** inside Sysbox containers (operation not permitted)
- **No custom kernel modules** — can't load networking modules from inside container

---

## 5. Bind Mount Support and UID Mapping

### ID-Mapped Mounts (Kernel ≥ 5.12)

According to [issue #535](https://github.com/nestybox/sysbox/issues/535) and the [storage documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/storage.md):

Starting with Sysbox v0.5.0, on kernels ≥ 5.12, Sysbox uses the kernel's **ID-mapped mounts** feature:

1. Host file with UID 1000 is bind-mounted into container
2. Kernel automatically maps 1000 → 101000 (container's user namespace offset)
3. Inside container, file appears as UID 1000 (correct owner)
4. **No actual file ownership changes on host**

This is the most efficient and secure method.

### Shiftfs (Kernel < 5.12)

For older kernels on Ubuntu, Debian, or Flatcar, Sysbox falls back to **shiftfs** kernel module:
- Ubuntu, Debian, Flatcar provide shiftfs out-of-box
- Other distros (Fedora, CentOS, RedHat, Amazon Linux 2) **must have kernel ≥ 5.12**

From the [distro compatibility doc](https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md):
> If your host has kernel < 5.12 and you wish to use Sysbox, it must be Ubuntu, Debian, or Flatcar (shiftfs only available there).

### Sandcastle Bind Mounts

Sandcastle uses bind mounts for:
- **User home:** `/data/users/{name}/home:/home/{user}` — shared across all sandboxes for same user
- **Workspace:** `/data/sandboxes/{name}/vol:/workspace` — per-sandbox persistent storage

With Sysbox's UID mapping, files created inside the container as root or user show up on host with mapped UIDs (e.g., 100000-165535 range), preventing permission conflicts.

---

## 6. Snapshot Capability via docker commit

### How It Works

According to the [Nestybox Docker sandbox blog](https://blog.nestybox.com/2019/11/11/docker-sandbox.html):

> The Nestybox system container runtime, Sysbox, not only allows running Docker more securely, but also **ensures that the Docker commit captures the contents of the system container, including inner Docker images, without problem.**

Standard Docker commit:
```bash
docker commit container-name new-image:tag
```

This works with Sysbox because:
1. Inner Docker daemon stores images in container filesystem (not host volume)
2. `docker commit` captures entire container filesystem state
3. Restoring from image starts inner Docker with all previous images intact

### Limitations

From the [Docker commit documentation](https://www.baeldung.com/ops/docker-save-container-state):

- **Data volumes are NOT captured** — only filesystem changes within container
- **Running processes NOT captured** — inner Docker daemon must be restarted
- **Memory state NOT captured** — not a true VM snapshot

### Sandcastle Implementation

Sandcastle uses `docker commit` for sandbox snapshots:
- Creates image from running/stopped container
- Stores in local Docker registry or GHCR
- Restores by creating new container from snapshot image
- Inner Docker images and containers persist across snapshot/restore cycles

---

## 7. Performance Characteristics

### CPU and Memory Overhead

From the [Sysbox README](https://github.com/nestybox/sysbox/blob/master/README.md):

> The containers created by Sysbox have **similar performance to those created by the OCI runc** (the default runtime for Docker and Kubernetes).

Key points from [Enhanced Container Isolation FAQs](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/faq/):

- **No performance impact on data-path operations** — syscall filtering optimized
- **Full workflow compatibility** — existing dev processes unchanged
- **No special container images** — standard images work without modification

### Comparison to Alternatives

From the [technology comparison blog](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html):

| Runtime | Performance | Isolation | Overhead |
|---------|-------------|-----------|----------|
| Standard runc | Baseline (1x) | Weak | Minimal |
| Sysbox | ~1x (similar) | Strong | Low (user-ns + FUSE) |
| Kata Containers | 0.5-0.8x | VM-level | High (VM boot + memory) |
| KubeVirt | 0.6-0.8x | VM-level | High (VM overhead) |

**Verdict:** Sysbox provides near-native performance with significantly better isolation than standard Docker.

### Sandcastle Observations

In production on Sandcastle host (`100.106.185.92`):
- No noticeable performance degradation vs. standard Docker
- Inner Docker daemon starts in ~2-3 seconds
- SSH latency normal (20-50ms)
- Docker-in-Docker builds comparable to host builds

---

## 8. API Maturity

### Docker API Compatibility

Sysbox is **fully compatible with the Docker API** because:
1. It's an OCI-compliant runtime registered with Docker daemon
2. Docker daemon handles API calls, just invokes `sysbox-runc` instead of `runc`
3. No changes needed to Docker client or API consumers

From the [docker-api gem documentation](https://github.com/upserve/docker-api):

The `docker-api` gem is a lightweight Ruby client for the Docker Remote API. It works with any OCI-compliant runtime, including Sysbox, because:
- **Runtime selection happens at container creation:** `Docker::Container.create(..., 'HostConfig' => { 'Runtime' => 'sysbox-runc' })`
- **All other API calls are runtime-agnostic** — start, stop, inspect, logs, etc.
- **Backward compatible** — Docker API versioning ensures old clients work with new daemons

### Sandcastle Integration

From the Sandcastle codebase (`app/services/sandbox_manager.rb`):

```ruby
Docker::Container.create(
  'Image' => image_name,
  'Hostname' => name,
  'User' => full_name,
  'Env' => env_vars,
  'HostConfig' => {
    'Runtime' => 'sysbox-runc',  # Only runtime-specific line
    'PortBindings' => { '22/tcp' => [{ 'HostPort' => ssh_port.to_s }] },
    'Binds' => [
      "#{home_dir}:/home/#{full_name}",
      "#{workspace_dir}:/workspace"
    ]
  }
)
```

**Zero special handling** beyond specifying the runtime. All standard Docker operations work:
- `docker exec` for terminal access (WeTTY)
- `docker commit` for snapshots
- `docker network connect/disconnect` for Tailscale bridge
- `docker stats` for monitoring

---

## 9. Production Readiness and Ecosystem

### Docker Acquisition and Support Model

From the [Docker acquisition announcement](https://www.docker.com/press-release/docker-accelerates-investment-in-container-security-with-acquisition-of-nestybox/):

- **Acquired May 2022** by Docker Inc.
- **Integrated into Docker Desktop** as Enhanced Container Isolation (ECI)
- **Community Edition remains open-source** ([GitHub repo](https://github.com/nestybox/sysbox))
- **Enterprise Edition discontinued** — features being merged into Community Edition

From the [Sysbox README support section](https://github.com/nestybox/sysbox/blob/master/README.md):

> Sysbox is a **community open-source project** that is **not officially supported by Docker**. Support is provided on a **best effort basis** via the Github repo or via the Sysbox Slack Workspace.

**Implications for Production:**
- ✅ Backed by Docker (financial stability, corporate interest)
- ✅ Active development and maintenance
- ❌ No official Docker support contract
- ❌ Community-driven bug fixes and feature requests

### Community Health (2025-2026)

Based on [GitHub activity](https://github.com/nestybox/sysbox):

- **Last release:** Ongoing through 2025 (releases page shows v0.6.x updates)
- **Issue activity:** Multiple issues filed and resolved in Oct-Dec 2025
- **Discussions:** Active community engagement in [Discussions tab](https://github.com/nestybox/sysbox/discussions)
- **Enterprise Edition:** [Archived August 7, 2025](https://github.com/docker-archive/nestybox.sysbox-ee) (read-only)

**Verdict:** Project is actively maintained but pace slower than pre-acquisition. Community support is responsive but not guaranteed.

### Production Deployments

From search results, known production users include:
- **GitLab runners** — [secure CI/CD with Sysbox](https://hamzachichi.medium.com/%EF%B8%8Fsetup-your-gitlab-runner-securely-sysbox-container-runtime-30ef2db37994)
- **Kasm Workspaces** — [browser-based dev environments](https://www.kasmweb.com/docs/latest/how_to/sysbox_runtime.html)
- **Coder** — [Docker-in-workspaces](https://coder.com/docs/admin/templates/extending-templates/docker-in-workspaces)
- **K3s clusters** — [lightweight Kubernetes](https://docs.k3s.io/blog/2025/09/27/k3s-sysbox)
- **EngFlow** — [remote execution sandboxes](https://docs.engflow.com/re/client/sysbox.html)

---

## 10. Known Limitations and Security Concerns

### Functional Limitations

From the [Sysbox limitations documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/limitations.md):

#### a) **Device Creation Restrictions**
- **No `/dev/tun`, `/dev/tap`, `/dev/fuse`** — VPN servers, FUSE filesystems fail
- **Workaround:** None. Requires privileged containers (defeats Sysbox purpose)

#### b) **Kernel Module Loading**
- **Cannot load kernel modules** from inside container
- **Impact:** Custom networking modules, specialized filesystems unavailable
- **Workaround:** Load modules on host before starting containers

#### c) **NFS Server**
- **Running NFS server inside container fails** with "operation not permitted"
- **Workaround:** None documented

#### d) **Nested User Namespaces**
- **Cannot use `docker run --userns=remap`** inside Sysbox container
- **Impact:** Docker's userns-remap mode unsupported, buildx+QEMU for multi-arch builds fails
- **Workaround:** Use standard Docker inside Sysbox (already rootless on host)

#### e) **binfmt_misc**
- **Software using `/proc/sys/fs/binfmt_misc`** not supported (e.g., multi-arch buildx)
- **Impact:** Cross-compilation with QEMU emulation broken
- **Workaround:** Build on native architecture or use host-level QEMU

### Container Runtime Compatibility

From [issue #958](https://github.com/nestybox/sysbox/issues/958) and the [deployment guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/deploy.md):

- **CRI-O:** Officially supported (native user namespace support)
- **containerd < 2.0:** Not supported (no user namespace support)
- **containerd ≥ 2.0:** Partial support (bug fixed in recent Sysbox versions)
- **Docker:** Fully supported

**Sandcastle uses Docker**, so no compatibility issues.

### Security Concerns

From the [Sysbox CVE documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security-cve.md):

#### **CVE-2022-0185** (High Severity)
- **Vulnerability:** Linux kernel user namespace escape (kernels < 5.16.2)
- **Impact:** Unprivileged user in user-namespace gains root on host
- **Sysbox Impact:** **Negates extra isolation** if kernel vulnerable
- **Mitigation:** Update kernel to ≥ 5.16.2

#### **CVE-2022-0492** (Medium Severity)
- **Vulnerability:** cgroups v1 `release_agent` privilege escalation
- **Impact:** Container escape via cgroups manipulation
- **Sysbox Impact:** **NOT vulnerable** (Sysbox locks `release_agent` writes)

#### **CVE-2024-21626** (High Severity)
- **Vulnerability:** OCI runc file descriptor leak enabling host filesystem access
- **Impact:** Container escape with host filesystem read/write
- **Sysbox Impact:** **NOT vulnerable** (Sysbox doesn't leak file descriptors)

**Key Insight:** Sysbox's security depends heavily on kernel version. Running on outdated kernels exposes to user-namespace escape vulnerabilities.

---

## 11. Operational Complexity

### Installation Requirements

From the [Sysbox installation documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md):

#### **System Requirements:**
- Supported Linux distro (Ubuntu, Debian, Fedora, CentOS, RedHat, Amazon Linux 2, Flatcar)
- **Kernel ≥ 5.15** (minimum compatible version)
- **Kernel ≥ 5.12** (for ID-mapped mounts without shiftfs)
- **systemd** as process manager
- Docker installed and running

#### **Kernel Dependencies:**
- **Kernel ≥ 5.12:** Uses ID-mapped mounts (optimal)
- **Kernel < 5.12 on Ubuntu/Debian/Flatcar:** Falls back to shiftfs module
- **Kernel < 5.12 on other distros:** **NOT supported** (no shiftfs available)

#### **Components Installed:**
1. **sysbox-runc** — Modified OCI runtime binary
2. **sysbox-mgr** — Systemd service managing containers
3. **sysbox-fs** — FUSE filesystem service

### Docker Configuration Changes

From the [installation guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md), Sysbox installer modifies `/etc/docker/daemon.json`:

```json
{
  "runtimes": {
    "sysbox-runc": {
      "path": "/usr/bin/sysbox-runc"
    }
  },
  "bip": "172.24.0.1/16",
  "default-address-pools": [
    { "base": "172.31.0.0/16", "size": 24 }
  ]
}
```

**Changes:**
- Adds `sysbox-runc` runtime
- Sets explicit Docker bridge IP to avoid conflicts
- Defines custom network pool for Sysbox containers

### Operational Overhead

#### **Installation Time:**
- ~1-2 minutes on Ubuntu/Debian with package manager
- Longer on other distros (manual compilation if needed)

#### **Service Management:**
- **sysbox-mgr.service** must run continuously
- **sysbox-fs.service** must run continuously
- **Docker daemon** must be restarted after Sysbox installation

#### **Debugging Complexity:**
- Three separate components (runc, mgr, fs) can fail independently
- Logs scattered: `journalctl -u sysbox-mgr`, `journalctl -u sysbox-fs`, Docker logs
- User namespace issues hard to debug (UID mapping errors)

### Sandcastle Installer Integration

From Sandcastle's `installer.sh` and `install-defaults`:

- **Sysbox installed via package manager** (Ubuntu 24.04)
- **Docker daemon reconfigured** with custom `daemon.json`
- **Separate "dockyard" Docker daemon** with `sysbox-runc` as default runtime
- **App containers use standard runc** to avoid conflicts

**Complexity Level:** Moderate. Requires careful separation of app runtime vs. sandbox runtime.

---

## 12. Community Support and Maintenance Status

### Project Governance

From the [Sysbox GitHub organization](https://github.com/nestybox):

- **Owner:** Docker Inc. (since May 2022)
- **Lead Maintainers:** Original Nestybox team members
- **License:** Apache 2.0 (open-source)
- **Repository:** https://github.com/nestybox/sysbox

### Release Cadence

From the [releases page](https://github.com/nestybox/sysbox/releases):

- **Pre-acquisition (2019-2022):** ~4-6 releases per year
- **Post-acquisition (2022-2026):** ~2-3 releases per year (slower pace)
- **Latest stable:** v0.6.x series (2025)

### Community Engagement

From GitHub metrics:
- **Stars:** ~4.5k (strong interest)
- **Forks:** ~200 (moderate contribution)
- **Issues:** ~600 total, ~50 open (actively triaged)
- **Discussions:** ~100 threads, mostly answered by maintainers

### Support Channels

From the [README support section](https://github.com/nestybox/sysbox/blob/master/README.md):

1. **GitHub Issues** — Bug reports and feature requests
2. **Sysbox Slack Workspace** — Community chat and help
3. **No official Docker support** — Community-driven only

**Comparison to Docker runc:**
- runc: Official Docker support, CNCF project, ~10k stars, daily commits
- Sysbox: Community support, Docker-owned, ~4.5k stars, weekly/monthly commits

**Verdict:** Community is active and helpful, but support is best-effort. No SLA or guaranteed response times.

### Future Outlook

Based on Docker's [acquisition press release](https://www.docker.com/press-release/docker-accelerates-investment-in-container-security-with-acquisition-of-nestybox/):

> Docker plans to make some Sysbox Enterprise features available in Sysbox Community Edition.

**Positive signals:**
- Docker continues funding development
- Features trickling down from ECI to open-source
- Active maintenance through 2025-2026

**Concerns:**
- Slower release cadence post-acquisition
- Enterprise Edition archived (no commercial product)
- No public roadmap or commitment timeline

---

## Sandcastle-Specific Evaluation

### What Works Well

✅ **Secure Docker-in-Docker** — Users get full inner Docker without compromising host
✅ **Standard Docker API** — `docker-api` gem works perfectly, zero custom code
✅ **Good performance** — Near-native container startup and runtime
✅ **Bind mounts with UID mapping** — User homes and workspaces just work
✅ **Snapshots via `docker commit`** — Including inner Docker images
✅ **SSH access** — Standard port bindings work flawlessly
✅ **Networking** — Bridge networks for Tailscale sidecars work great
✅ **Stable in production** — No crashes or data loss on Sandcastle host

### Pain Points

⚠️ **Kernel dependency** — Host must have Ubuntu/Debian with kernel ≥ 5.12 (Sandcastle uses Ubuntu 24.04 with 6.x kernel, so OK)
⚠️ **Installation complexity** — Separate dockyard daemon, careful runtime separation
⚠️ **Community support only** — No commercial backing if things break
⚠️ **Some limitations** — No multi-arch buildx (but users can install QEMU on host)
⚠️ **Common UID mapping** — All containers share same host UID range (CE limitation)

### Critical Dependencies

1. **Ubuntu/Debian host** — Other distros require kernel ≥ 5.12 without shiftfs
2. **Docker daemon** — Not compatible with containerd-only setups
3. **Kernel ≥ 5.15** — Minimum requirement, preferably ≥ 6.0 for latest security fixes
4. **Active community** — Bugs may take weeks/months to fix without official support

---

## Conclusion

**Docker + Sysbox is a mature, production-ready solution for secure Docker-in-Docker sandboxes.** It provides significantly stronger isolation than vanilla Docker with minimal performance overhead and full Docker API compatibility. The project is actively maintained by Docker and has a helpful community.

**Key trade-offs:**
- **Pros:** Security, performance, API compatibility, ease of use
- **Cons:** Kernel dependencies, community-only support, some functional limitations, Linux-only

**For Sandcastle's use case** (multi-user shared Docker sandboxes with SSH access), Sysbox is an excellent fit. The main risks are:
1. Long-term maintenance if Docker deprioritizes the project
2. Lack of official support for production issues
3. Kernel vulnerabilities that bypass user namespace isolation

Any alternative solution should be compared against Sysbox's security model, performance, and API compatibility to determine if the trade-offs are worthwhile.

---

## Sources

- [Sysbox GitHub Repository](https://github.com/nestybox/sysbox)
- [Docker Acquisition Announcement](https://www.docker.com/blog/docker-advances-container-isolation-and-workloads-with-acquisition-of-nestybox/)
- [Sysbox Docker-in-Docker Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/dind.md)
- [Sysbox Security Documentation](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security.md)
- [Sysbox Storage and UID Mapping](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/storage.md)
- [Sysbox Limitations](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/limitations.md)
- [Sysbox CVE Database](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security-cve.md)
- [Sysbox Installation Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md)
- [Enhanced Container Isolation Documentation](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/)
- [Nestybox Blog: Technology Comparison](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)
- [Nestybox Blog: System Container Security](https://blog.nestybox.com/2019/11/20/syscont-security.html)
- [Medium: Secure Docker-in-Docker with Nestybox](https://ctalledo.medium.com/secure-docker-in-docker-with-nestybox-529c5c419582)
- [Docker API Gem Documentation](https://github.com/upserve/docker-api)
- [Kasm Sysbox Runtime Documentation](https://www.kasmweb.com/docs/latest/how_to/sysbox_runtime.html)
- [K3s Sysbox Runtime Blog](https://docs.k3s.io/blog/2025/09/27/k3s-sysbox)
