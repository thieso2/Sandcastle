# Container Isolation Technology Comparison for Sandcastle

**Date:** February 13, 2026
**Project:** Sandcastle — Self-hosted shared sandbox platform
**Current Solution:** Docker + Sysbox runtime
**Goal:** Evaluate alternative isolation technologies

---

## Executive Summary

After comprehensive research of five container/VM isolation technologies, **Docker + Sysbox remains the best fit** for Sandcastle. All evaluated alternatives have critical blockers that make them unsuitable:

| Technology | Critical Blocker | Recommendation |
|------------|-----------------|----------------|
| **Docker + Sysbox** | None (current solution) | ✅ **Keep as primary solution** |
| **Firecracker** | No filesystem sharing support | ❌ Not viable |
| **Flintlock** | Nested virtualization not supported | ❌ Not viable |
| **gVisor** | Docker-in-Docker with tmpfs-only (ephemeral) | ❌ Not viable |
| **Kata Containers** | 2-4x slower Docker-in-Docker, nested virt required | ⚠️ Unsuitable for current use case |

### Key Insight

**Docker-in-Docker is Sandcastle's core feature**, and only Sysbox is optimized for this use case while maintaining:
- Standard Docker API compatibility
- Near-native performance
- Simple operational model
- No nested virtualization requirements
- Full bind mount support

---

## Sandcastle Requirements Matrix

| Requirement | Priority | Docker+Sysbox | Firecracker | Flintlock | gVisor | Kata |
|------------|----------|---------------|-------------|-----------|--------|------|
| **Docker-in-Docker** | CRITICAL | ✅ Optimized | ⚠️ Nested KVM | ❌ No nested | ⚠️ Ephemeral | ❌ 2-4x slower |
| **SSH Access** | CRITICAL | ✅ Native | ✅ Native | ✅ Native | ✅ Native | ✅ Native |
| **Bind Mounts** | CRITICAL | ✅ Native | ❌ No support | ❌ No support | ✅ Native | ⚠️ 40-50% slower |
| **Port Binding** | HIGH | ✅ Simple `-p` | ⚠️ Manual iptables | ⚠️ Manual iptables | ✅ Simple `-p` | ✅ Simple `-p` |
| **Dynamic Networking** | HIGH | ✅ Connect/disconnect | ❌ No hot-plug | ❌ No hot-plug | ✅ Native | ⚠️ Limited |
| **Snapshots** | HIGH | ✅ docker commit | ✅ Fast (4-10ms) | ✅ Via Firecracker | ⚠️ No network state | ⚠️ Filesystem only |
| **Security Isolation** | HIGH | ⚠️ Kernel-level | ✅ Hardware (VM) | ✅ Hardware (VM) | ✅ Userspace kernel | ✅ Hardware (VM) |
| **API Maturity** | HIGH | ✅ docker-api gem | ⚠️ HTTP (no SDK) | ⚠️ gRPC (no SDK) | ✅ docker-api gem | ✅ docker-api gem |
| **Performance** | MEDIUM | ✅ Near-native | ✅ Excellent | ✅ Excellent | ⚠️ 10x syscall overhead | ⚠️ 5-10% CPU |
| **Operational Complexity** | MEDIUM | ⚠️ Moderate | ❌ High | ❌ High | ✅ Low | ⚠️ Moderate |
| **Production Readiness** | HIGH | ✅ Proven | ✅ AWS Lambda scale | ⚠️ Niche community | ✅ Google Cloud scale | ✅ Alibaba scale |
| **Deployment Flexibility** | MEDIUM | ✅ Any Linux | ⚠️ Bare metal/nested | ⚠️ Bare metal | ✅ Any Linux | ⚠️ Bare metal/nested |

**Legend:**
- ✅ Fully supported / Excellent
- ⚠️ Limited support / Has issues
- ❌ Not supported / Critical blocker

---

## Detailed Technology Analysis

### 1. Docker + Sysbox (Current Solution)

**What it is:** OCI-compatible runtime that enables secure Docker-in-Docker via Linux user namespaces and syscall interception.

#### Pros for Sandcastle ✅

1. **Perfect Docker-in-Docker Support**
   - Optimized specifically for this use case
   - No privileged containers needed
   - Inner Docker fully isolated from host daemon
   - Supports all Docker features (build, compose, volumes)

2. **Standard API Compatibility**
   - Uses `docker-api` Ruby gem with zero custom code
   - Drop-in replacement for `runc` (just add `Runtime: 'sysbox-runc'`)
   - All Docker tooling works (CLI, Compose, SDKs)

3. **Near-Native Performance**
   - Minimal overhead from user namespaces
   - ~1% CPU overhead, ~5% I/O overhead
   - No noticeable degradation in production

4. **Production-Proven**
   - 4+ years of development
   - Docker corporate backing since 2022
   - Used by GitLab, Kasm, Coder, K3s

5. **Full Feature Support**
   - Bind mounts with UID mapping (world-writable 777)
   - Dynamic networking (connect/disconnect)
   - Port bindings (2201-2299 range for SSH)
   - Snapshots via `docker commit` capture inner Docker state
   - Tailscale and WeTTY integration work seamlessly

6. **Deployment Flexibility**
   - Runs on any Linux with kernel ≥ 5.15
   - No nested virtualization required
   - Compatible with cloud VMs (AWS, GCP, Azure)

#### Cons for Sandcastle ⚠️

1. **Weaker Isolation Than VMs**
   - Shared kernel (kernel exploits can escape)
   - CVE-2022-0185 allowed user namespace escape on kernels < 5.16.2
   - Depends on kernel security

2. **Installation Complexity**
   - Three components: sysbox-runc, sysbox-mgr, sysbox-fs
   - Custom Docker daemon config required
   - Separate "dockyard" daemon for Sandcastle (iptables isolation)

3. **Kernel Dependencies**
   - Requires Linux ≥ 5.15 (preferably ≥ 5.12 for ID-mapped mounts)
   - Ubuntu/Debian need shiftfs or kernel ≥ 5.12
   - **Mitigated:** Sandcastle uses Ubuntu 24.04 with kernel 6.x

4. **Some Feature Limitations**
   - Multi-arch builds broken (buildx + QEMU doesn't work)
   - No device creation (/dev/tun, /dev/tap, /dev/fuse)
   - Can't load kernel modules
   - NFS server won't work inside containers

5. **Community-Only Support**
   - No commercial SLA from Docker
   - Slower release cadence post-acquisition (2-3/year)
   - ~50 open issues on GitHub

6. **Common UID Mapping (CE Limitation)**
   - All Sysbox containers share same UID mapping (100000-165535)
   - CE version can't customize per-container UIDs
   - Potential (theoretical) cross-container file access if paths collide
   - **Mitigated:** Separate user homes prevent collisions

#### Current Status in Sandcastle

**Working Well:**
- Secure Docker-in-Docker for 2+ years in production
- SSH access (ports 2201-2299)
- Bind mounts: user homes, workspaces, data directories
- Tailscale bridge networks (per-user sidecars)
- WeTTY web terminals (ephemeral sidecars)
- HTTP routing via Traefik dynamic config
- Snapshots via `docker commit`

**Pain Points:**
- Installation complexity (separate dockyard daemon)
- UID mapping requires 777 permissions on bind mounts
- Occasional UID mapping confusion during debugging

**Verdict:** Works well for Sandcastle's needs. Known limitations are acceptable trade-offs.

---

### 2. Firecracker

**What it is:** Lightweight microVM manager using KVM, developed by AWS for Lambda and Fargate.

#### Pros ✅

1. **Strongest Security Isolation**
   - Hardware-level virtualization via KVM
   - Separate kernel per microVM
   - Powers AWS Lambda (trillions of requests/month)
   - Protects against container escape exploits

2. **Excellent Performance**
   - Boot time: 125ms-1s (2-4x faster than Docker + Sysbox)
   - Memory overhead: <5 MiB per microVM
   - Near-native CPU performance (>95%)

3. **Fast Snapshots**
   - 4-10ms snapshot/restore times
   - Copy-on-write root disk images
   - Ideal for serverless use cases

4. **Battle-Tested at Scale**
   - AWS Lambda, Fargate (production at massive scale)
   - Fly.io (infrastructure platform)
   - E2B (code execution sandbox)

#### Cons ⚠️❌

1. **❌ CRITICAL BLOCKER: No Filesystem Sharing**
   - Firecracker does **not support virtio-fs or 9p**
   - Cannot bind-mount host directories
   - **Breaks Sandcastle's architecture:**
     - User homes: `/data/users/{name}/home` → `/home/{user}`
     - Workspaces: `/data/sandboxes/{name}/vol` → `/workspace`
     - Data dirs: `/data/users/{name}/data/{path}` → `/data`
   - Workarounds (block devices, network filesystems) add massive complexity

2. **Complex Networking**
   - Manual TAP device creation per VM
   - Manual IP allocation and routing
   - Manual iptables rules for port forwarding
   - No Docker-style `-p 2201:22` convenience
   - Requires deep Linux networking expertise

3. **No Dynamic Network Configuration**
   - Cannot add/remove network interfaces after boot
   - Must recreate VM to change networking
   - **Breaks Sandcastle UX:**
     - WeTTY: Dynamic connection to `sandcastle-web` network
     - Tailscale: Dynamic connection to per-user bridge `sc-ts-net-{user}`

4. **High Operational Complexity**
   - Must manage: kernel images, rootfs images, jailer config, process lifecycle
   - No `docker exec` equivalent (SSH or vsock required)
   - Lower-level API than Docker
   - Would need custom Ruby HTTP client (no SDK)

5. **Docker-in-Docker Requires Nested KVM**
   - Not available on standard cloud VMs
   - Complicates deployment
   - Performance impact from nested virtualization

6. **Different Mental Model**
   - VMs, not containers
   - Immutable configuration after boot
   - More like AWS Lambda than Docker

#### Implementation Complexity

**Estimated effort:** 8-12 weeks full-time
- Build Ruby HTTP client for Firecracker API
- TAP device manager service
- Custom networking layer (IP allocation, routing, iptables)
- Block device management for storage
- VM lifecycle orchestration
- Migrate snapshots from Docker images to disk snapshots

**Maintenance burden:** Significantly higher than Docker

#### Verdict for Sandcastle

**❌ Not Viable:** The lack of filesystem sharing is a fundamental blocker that cannot be worked around without massive architectural changes. Even if this were solved, the networking complexity and lack of dynamic reconfiguration would severely complicate Tailscale and WeTTY integrations.

**When Firecracker Would Make Sense:**
- Serverless code execution (Lambda-style)
- Ephemeral workloads with no persistent storage
- High-security untrusted code execution
- Organizations with deep infrastructure expertise

---

### 3. Flintlock

**What it is:** gRPC service for managing Firecracker microVMs via containerd integration, developed by Weaveworks for Liquid Metal project.

#### Pros ✅

1. **Higher-Level Abstraction Than Raw Firecracker**
   - gRPC API instead of low-level HTTP
   - Containerd integration for image management
   - Simplified VM lifecycle management

2. **Kubernetes Integration**
   - Designed for cluster-API providers
   - Can run Kubernetes nodes as microVMs
   - Good for bare-metal Kubernetes

3. **Inherits Firecracker Security**
   - Hardware-level VM isolation
   - KVM-based security boundary

#### Cons ⚠️❌

1. **❌ CRITICAL BLOCKER: Nested Virtualization Not Supported**
   - Firecracker requires direct KVM access
   - Cannot run inside Docker containers (where Sandcastle Rails app lives)
   - **Architectural mismatch:** Would require moving Flintlock to bare metal outside Docker

2. **Still Has Firecracker's Networking Issues**
   - Manual iptables for port forwarding
   - No hot-plug networking
   - Regression from Docker's simple `-p` bindings

3. **Project Maturity Concerns**
   - Community-led after Weaveworks shutdown (2023)
   - Inconsistent release cadence
   - Small community (no production users documented outside Kubernetes niche)
   - Last stable release: v0.3.0 (Dec 2022)

4. **Docker-in-Docker Still Problematic**
   - Inherits Firecracker's nested KVM requirement
   - Still no filesystem sharing

5. **Architectural Mismatch**
   - Designed for Kubernetes-on-bare-metal edge computing
   - Not designed for shared developer sandboxes
   - Overkill for Sandcastle's use case

6. **No Ruby SDK**
   - gRPC API would require custom Protobuf client
   - More complex than Docker API gem

#### Implementation Complexity

**Estimated effort:** 10-14 weeks
- Deploy Flintlock on bare metal (outside Docker)
- Network architecture redesign
- gRPC client library for Ruby
- Migration from Docker-based deployment

#### Verdict for Sandcastle

**❌ Not Suitable:** Flintlock is an abstraction over Firecracker, which itself is unsuitable for Sandcastle. The nested virtualization blocker and project maturity concerns make this a non-starter. Flintlock solves problems Sandcastle doesn't have (Kubernetes-on-bare-metal) while introducing new ones.

**When Flintlock Would Make Sense:**
- Kubernetes clusters on bare metal
- Edge computing with microVM nodes
- Organizations already invested in Liquid Metal ecosystem

---

### 4. gVisor

**What it is:** Userspace kernel written in Go that intercepts syscalls, providing strong isolation without hardware virtualization.

#### Pros ✅

1. **Strong Isolation Without VMs**
   - Userspace kernel reduces attack surface
   - Protects against kernel exploits (e.g., CVE-2020-14386)
   - No nested virtualization required

2. **OCI-Compatible Drop-In Replacement**
   - Works with Docker API via `runsc` runtime
   - Uses `docker-api` gem with `Runtime: 'runsc'` parameter
   - Compatible with existing tooling

3. **Production-Proven at Scale**
   - Powers Google Cloud Run, App Engine, Cloud Functions
   - Handles billions of containers
   - Active development (Google-backed)

4. **Recent Performance Improvements**
   - Directfs: Bypasses Gofer for better I/O (40% improvement)
   - Rootfs overlay: Reduced memory usage
   - Systrap platform: Lower syscall overhead

5. **No Kernel Dependencies**
   - Runs on any Linux kernel
   - No shiftfs or ID-mapped mounts needed

#### Cons ⚠️❌

1. **❌ CRITICAL BLOCKER: Docker-in-Docker Limitation**
   - Requires tmpfs-only upper layers for overlay filesystems
   - **All Docker container changes are ephemeral** (lost on restart)
   - **Breaks persistent workspace model:** `/data/sandboxes/{name}/vol:/workspace`
   - Cannot persist Docker builds, volumes, or state

2. **Performance Overhead**
   - 10x+ syscall overhead on KVM platform (Gofer architecture)
   - I/O and network-heavy workloads (Docker builds) see significant degradation
   - Recent optimizations help but don't eliminate overhead

3. **Limited Syscall Support**
   - Only 274/350 syscalls implemented (78%)
   - May cause compatibility issues with some developer tools
   - Edge cases harder to debug

4. **No Network State in Snapshots**
   - Checkpoint/restore doesn't preserve TCP connections
   - Limits snapshot usefulness for running containers

5. **Complex Architecture**
   - Multiple components: runsc, Gofer, Netstack, platform interceptor
   - Harder to debug than standard containers
   - More moving parts to maintain

#### Docker-in-Docker Technical Details

From gVisor documentation ([source](https://gvisor.dev/docs/tutorials/docker-in-gvisor/)):
```
When Docker mounts an overlay filesystem, the upper layer must be tmpfs.
This means all container changes are in-memory and ephemeral.
```

**Impact on Sandcastle:**
- Users lose Docker container state on sandbox restart
- No persistent workspaces
- Defeats the purpose of `/workspace` volumes
- Would require complete architectural rework

#### Implementation Complexity

**Estimated effort:** 2-3 weeks (easy to test)
- Add `runsc` runtime to Docker daemon
- Update SandboxManager to use `Runtime: 'runsc'`
- Test compatibility

**BUT:** Docker-in-Docker limitation is a fundamental blocker, not a configuration issue.

#### Verdict for Sandcastle

**❌ Not Viable:** The tmpfs-only requirement for Docker-in-Docker makes gVisor unsuitable for Sandcastle's persistent workspace model. This is a fundamental architectural limitation, not something that can be configured or worked around.

**When gVisor Would Make Sense:**
- Ephemeral code execution (no persistent state)
- Stateless web services
- Short-lived batch jobs
- Organizations prioritizing security over Docker-in-Docker compatibility

---

### 5. Kata Containers

**What it is:** OCI-compatible runtime that runs containers inside lightweight VMs with separate kernels, supporting multiple hypervisors (QEMU, Cloud Hypervisor, Firecracker).

#### Pros ✅

1. **OCI-Compatible Drop-In Replacement**
   - Works with Docker API via `kata-runtime`
   - Uses `docker-api` gem with `Runtime: 'kata-runtime'`
   - Compatible with Docker, containerd, Kubernetes

2. **Strongest Security Isolation**
   - Hardware-level VM boundary
   - Separate kernel per container
   - Protects against kernel exploits

3. **Port Binding Works Identically**
   - SSH on ports 2201-2299 works as expected
   - No manual iptables rules needed
   - Standard Docker networking

4. **Production-Proven**
   - Used by Alibaba Cloud (production)
   - IBM Cloud, Baidu (production)
   - Active community (OpenInfra Foundation)

5. **Multiple Hypervisor Options**
   - Cloud Hypervisor (recommended, fastest)
   - QEMU (most compatible)
   - Firecracker (AWS optimized)

6. **Bind Mount Support**
   - Supports host directory bind mounts
   - Compatible with Sandcastle's volume architecture

#### Cons ⚠️❌

1. **❌ CRITICAL: Docker-in-Docker Performance Issues**
   - **2-4x slower** for Docker builds
   - **2-3x slower** for image pulls
   - **15-50% I/O degradation** on bind mounts
   - **This is Sandcastle's core use case** — unacceptable performance

2. **Nested Virtualization Required**
   - Must run on bare metal OR cloud VMs with nested virt enabled
   - Standard AWS EC2/GCP instances don't support this
   - Significantly increases deployment complexity
   - Performance impact from nested virtualization

3. **No Native Snapshot/Restore**
   - OCI spec doesn't require checkpoint/restore
   - `docker commit` only saves filesystem, not VM state
   - Requires custom runtime modifications for VM-level snapshots

4. **Higher Resource Overhead**
   - 15-30MB memory per container (vs 10-50MB for Sysbox)
   - 5-10% CPU overhead
   - Slower boot times (125-500ms vs ~50ms for Sysbox)

5. **Network Namespace Sharing Not Supported**
   - Cannot share network namespaces with runc containers
   - Potential complications with Tailscale bridge networks
   - Would need testing to validate

6. **Hypervisor Selection Trade-offs**
   - QEMU: slowest boot (500ms), highest compatibility
   - Cloud Hypervisor: fastest boot (125ms), less mature
   - Firecracker: balanced, but AWS-specific optimizations

#### Docker-in-Docker Performance

From performance benchmarks ([source](https://northflank.com/blog/kata-containers-vs-firecracker-vs-gvisor)):
- Docker build: 2-4x slower than runc
- Docker pull: 2-3x slower than runc
- Bind mount I/O: 15-50% of bare metal performance

**Impact on Sandcastle:**
- Users experience slow Docker builds in sandboxes
- Image pulls are frustratingly slow
- File I/O in `/workspace` is degraded
- Poor user experience for core feature

#### Implementation Complexity

**Estimated effort:** 3-4 weeks
- Install Kata runtime and hypervisor
- Verify nested virtualization support
- Update SandboxManager to use `Runtime: 'kata-runtime'`
- Test all integrations (SSH, Tailscale, WeTTY)
- Performance testing and optimization attempts

#### Verdict for Sandcastle

**⚠️ Unsuitable for Current Use Case:** While Kata is technically feasible and OCI-compatible, the **2-4x performance degradation for Docker-in-Docker** makes it a poor fit for Sandcastle. Users would experience noticeably slower builds and file operations, hurting the core value proposition.

**Additional Concerns:**
- Nested virtualization requirement limits deployment options
- Increased complexity vs Sysbox without clear benefits
- Higher resource overhead at scale

**When Kata Would Make Sense:**
- Running on bare metal infrastructure
- Hardware isolation is a compliance requirement
- Docker-in-Docker is not the primary use case
- Performance trade-off is acceptable for security gains

**Possible Future Consideration:**
- If Cloud Hypervisor or Firecracker optimize Docker-in-Docker performance
- If nested virtualization becomes widely available
- If Sandcastle adds a "high-security tier" for truly untrusted code

---

## Performance Comparison

| Metric | Docker+Sysbox | Firecracker | Flintlock | gVisor | Kata |
|--------|---------------|-------------|-----------|--------|------|
| **Boot Time** | 2-5s | 125ms-1s ✅ | 125ms-1s ✅ | 2-5s | 125-500ms |
| **Memory/Container** | 10-50MB | <5MB ✅ | <5MB ✅ | 10-50MB | 15-30MB |
| **CPU Overhead** | ~1% ✅ | ~5% | ~5% | ~10% | ~5-10% |
| **I/O Overhead** | ~5% ✅ | N/A (no mounts) | N/A (no mounts) | ~30-60% | ~40-50% |
| **Docker Build Speed** | Baseline ✅ | N/A (DinD hard) | N/A (DinD hard) | Slower (tmpfs) | 2-4x slower ❌ |
| **Syscall Overhead** | Minimal ✅ | None (native) ✅ | None (native) ✅ | 10x+ ❌ | Minimal |
| **Network Latency** | Baseline ✅ | Baseline ✅ | Baseline ✅ | +10-20% | Baseline |

**Winner for Sandcastle:** Docker + Sysbox (near-native performance for Docker-in-Docker use case)

---

## Security Comparison

### Isolation Strength (Weakest → Strongest)

1. **Docker (vanilla runc)** — Kernel namespaces only
2. **Docker + Sysbox** — User namespaces + syscall interception
3. **gVisor** — Userspace kernel (application-layer boundary)
4. **Kata Containers** — Hardware VM isolation
5. **Firecracker/Flintlock** — Hardware VM isolation (minimal attack surface)

### Attack Surface Analysis

| Technology | Kernel | Syscall Attack Surface | Escape Difficulty |
|------------|--------|----------------------|------------------|
| Docker+Sysbox | Shared | Reduced via interception | Medium |
| Firecracker | Separate | Minimal (hypervisor only) | Very High ✅ |
| Flintlock | Separate | Minimal (hypervisor only) | Very High ✅ |
| gVisor | Shared | Userspace kernel (274/350 syscalls) | High |
| Kata | Separate | Minimal (hypervisor only) | Very High ✅ |

### Known Vulnerabilities

**Sysbox:**
- ❌ CVE-2022-0185: Kernel escape on kernels < 5.16.2 (mitigated with Ubuntu 24.04 kernel 6.x)
- ✅ CVE-2022-0492: Sysbox NOT vulnerable
- ✅ CVE-2024-21626: Sysbox NOT vulnerable

**Firecracker:**
- Minimal attack surface by design
- No major CVEs affecting production

**gVisor:**
- ✅ Protected against CVE-2020-14386 (kernel exploit)
- Userspace kernel limits kernel exploit impact

**Kata:**
- VM isolation provides strong protection
- Hypervisor vulnerabilities (QEMU has CVEs, but rare escapes)

### Security Verdict

**For Sandcastle's threat model (shared developer sandboxes, trusted-but-isolated users):**
- Sysbox provides **sufficient isolation** with kernel-level boundaries + user namespaces
- VM-based solutions (Firecracker, Kata) provide **stronger isolation** but with significant trade-offs
- gVisor provides **good isolation** but Docker-in-Docker limitation is a blocker

**Recommendation:** Stick with Sysbox unless:
- Running truly untrusted code (malware analysis, arbitrary code execution)
- Compliance requires hardware isolation
- Multi-tenant SaaS with strict isolation requirements

---

## Operational Complexity Comparison

### Installation & Setup

| Technology | Complexity | Components | Configuration |
|------------|-----------|-----------|---------------|
| Docker+Sysbox | ⚠️ Moderate | 3 daemons (Docker, sysbox-mgr, sysbox-fs) | Custom daemon.json |
| Firecracker | ❌ High | VMM per VM, jailer, TAP manager | Kernel, rootfs, networking |
| Flintlock | ❌ High | Flintlock, containerd, Firecracker | gRPC, containerd config |
| gVisor | ✅ Low | runsc binary | Add runtime to daemon.json |
| Kata | ⚠️ Moderate | kata-runtime, hypervisor | Add runtime to daemon.json |

### Day-to-Day Operations

| Technology | Debugging | Monitoring | Upgrades |
|------------|----------|-----------|----------|
| Docker+Sysbox | ⚠️ Moderate (UID mapping) | ✅ Docker tools | ✅ apt upgrade |
| Firecracker | ❌ Complex (VM internals) | ⚠️ Custom tooling | ⚠️ Manual binaries |
| Flintlock | ❌ Complex (gRPC + VM) | ⚠️ Custom tooling | ⚠️ gRPC updates |
| gVisor | ⚠️ Moderate (runsc logs) | ✅ Docker tools | ✅ apt upgrade |
| Kata | ⚠️ Moderate (VM logs) | ✅ Docker tools | ⚠️ Hypervisor + runtime |

### Team Expertise Required

| Technology | Required Knowledge |
|------------|-------------------|
| Docker+Sysbox | Docker, user namespaces, basic Linux |
| Firecracker | KVM, TAP networking, iptables, VM management |
| Flintlock | gRPC, Firecracker, containerd, Kubernetes |
| gVisor | Docker, syscall tracing (for debugging) |
| Kata | Docker, hypervisors, nested virtualization |

**Winner for Sandcastle:** gVisor (if Docker-in-Docker wasn't a blocker), otherwise Sysbox

---

## Deployment Flexibility

| Technology | Cloud VMs | Bare Metal | Containers | Nested Virt Required |
|------------|-----------|-----------|-----------|---------------------|
| Docker+Sysbox | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| Firecracker | ⚠️ Limited | ✅ Yes | ❌ No | ⚠️ For DinD |
| Flintlock | ⚠️ Limited | ✅ Yes | ❌ No | ⚠️ For DinD |
| gVisor | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| Kata | ⚠️ With nested | ✅ Yes | ❌ No | ✅ Yes |

**Current Sandcastle Deployment:**
- Cloud VM: Hetzner bare metal (100.106.185.92 via Tailscale)
- Rails app runs in Docker container
- Sandboxes run via dockyard Docker daemon with Sysbox runtime

**Winner for Sandcastle:** Docker + Sysbox (works everywhere Docker works)

---

## Migration Complexity

### Estimated Effort to Switch from Sysbox

| To Technology | Effort | Risk | Reversibility |
|--------------|--------|------|--------------|
| Firecracker | 8-12 weeks | ❌ High | ⚠️ Moderate |
| Flintlock | 10-14 weeks | ❌ High | ⚠️ Moderate |
| gVisor | 2-3 weeks | ✅ Low | ✅ Easy |
| Kata | 3-4 weeks | ⚠️ Moderate | ✅ Easy |

### Migration Tasks by Technology

**Firecracker:**
- Build Ruby HTTP client
- Implement TAP device manager
- Rewrite networking layer (IP allocation, routing, iptables)
- Replace bind mounts with block devices (major architecture change)
- VM lifecycle orchestration
- Snapshot format migration
- Test all integrations (Tailscale, WeTTY, HTTP routing)

**Flintlock:**
- All Firecracker tasks, plus:
- Deploy Flintlock on bare metal
- Build gRPC client
- Architectural redesign (move outside Docker)

**gVisor:**
- Install runsc runtime
- Update SandboxManager to use runsc
- Test Docker-in-Docker
- **BLOCKER:** Discover ephemeral Docker limitation
- Abandon migration

**Kata:**
- Install kata-runtime and hypervisor
- Verify nested virtualization support
- Update SandboxManager to use kata-runtime
- Performance testing
- **DECISION POINT:** Accept 2-4x slower Docker builds or abandon

---

## Cost Analysis

### Infrastructure Costs (at scale: 100 active sandboxes)

| Technology | Memory (GB) | CPU Overhead | Storage Overhead | Total Cost Impact |
|------------|------------|-------------|-----------------|------------------|
| Docker+Sysbox | 1-5 GB | +1% | Minimal | Baseline |
| Firecracker | 0.5 GB | +5% | High (separate kernels) | -50% memory, +20% storage |
| Flintlock | 0.5 GB | +5% | High (separate kernels) | -50% memory, +20% storage |
| gVisor | 1-5 GB | +10% | Minimal | +10% CPU |
| Kata | 1.5-3 GB | +5-10% | High (separate kernels) | +50% memory |

### Development/Operations Costs

| Technology | Initial Dev | Ongoing Maintenance | Incident Response |
|------------|------------|-------------------|------------------|
| Docker+Sysbox | ✅ Done | ⚠️ Moderate | ✅ Known issues |
| Firecracker | ❌ 8-12 weeks | ❌ High | ❌ New expertise |
| Flintlock | ❌ 10-14 weeks | ❌ High | ❌ New expertise |
| gVisor | ✅ 2-3 weeks | ⚠️ Moderate | ⚠️ Syscall debugging |
| Kata | ⚠️ 3-4 weeks | ⚠️ Moderate | ⚠️ Hypervisor issues |

**Winner:** Sysbox (sunk cost already paid, known operational model)

---

## Recommendations

### Short-Term (Next 6 months)

**✅ Recommendation: Keep Docker + Sysbox**

**Rationale:**
1. **No better alternatives exist** — All evaluated technologies have critical blockers
2. **Sysbox works well in production** — 2+ years of stable operation
3. **Migration risks outweigh benefits** — 8-14 weeks effort, uncertain outcomes
4. **Security is sufficient** — Kernel-level isolation adequate for developer sandboxes

**Actions:**
- ✅ Monitor Sysbox project health (Docker stewardship, release cadence)
- ✅ Keep kernel updated (Ubuntu 24.04 provides kernel 6.x)
- ✅ Document known limitations in operations runbook
- ✅ Watch for CVEs affecting user namespaces or Sysbox

### Medium-Term (6-18 months)

**Monitor alternative technologies for improvements:**

1. **Firecracker** — Watch for:
   - virtio-fs or 9p filesystem sharing support
   - Hot-plug networking capability
   - Ruby SDK development

2. **Kata Containers** — Watch for:
   - Docker-in-Docker performance optimizations
   - Cloud Hypervisor maturity
   - Nested virtualization availability on major cloud providers

3. **gVisor** — Watch for:
   - Docker-in-Docker persistent overlay support
   - Continued performance improvements (Directfs evolution)

**Re-evaluate if:**
- Major CVE affects Sysbox or user namespaces
- Docker stops maintaining Sysbox
- Compliance requirements mandate hardware isolation
- Customer demand for higher isolation tier

### Long-Term (18+ months)

**Consider hybrid approach if isolation becomes critical:**

```
┌─────────────────────────────────────────┐
│         Sandcastle Platform             │
├─────────────────────────────────────────┤
│                                         │
│  [Standard Tier]    [High-Security Tier]│
│   Docker + Sysbox   Kata / Firecracker │
│   - Default         - Opt-in            │
│   - Fast            - Slower            │
│   - $10/month       - $25/month         │
│                                         │
└─────────────────────────────────────────┘
```

**Benefits:**
- Serve both use cases (dev sandboxes + untrusted code)
- Charge premium for hardware isolation
- Gain experience with VM-based tech incrementally

**Requirements for hybrid approach:**
- Implement container service abstraction layer (Phase 1 from Issue #17)
- Test VM-based backend on subset of users
- Clear documentation of tier differences
- Pricing model that covers infrastructure costs

---

## Decision Matrix

### When to Choose Each Technology

| Technology | Best For | Avoid If |
|------------|----------|----------|
| **Docker+Sysbox** | • Developer sandboxes<br>• Docker-in-Docker priority<br>• Standard cloud VMs<br>• Small teams | • Hardware isolation required<br>• Compliance mandates VMs<br>• Truly untrusted code |
| **Firecracker** | • Serverless platforms<br>• Ephemeral workloads<br>• No persistent storage<br>• Deep infra expertise | • Need bind mounts<br>• Docker-in-Docker is core<br>• Dynamic networking needed<br>• Small team |
| **Flintlock** | • Kubernetes on bare metal<br>• Edge computing<br>• Liquid Metal users | • Standard shared sandboxes<br>• Docker-in-Docker<br>• Small team<br>• Need maturity |
| **gVisor** | • Ephemeral code execution<br>• Stateless services<br>• Google Cloud ecosystem | • Persistent Docker-in-Docker<br>• I/O-intensive workloads<br>• Need full syscall compat |
| **Kata** | • Bare metal infra<br>• Compliance requirements<br>• Non-Docker-heavy workloads | • Docker-in-Docker is core<br>• Performance critical<br>• Standard cloud VMs |

### Sandcastle-Specific Decision Tree

```
Do you need Docker-in-Docker?
├─ Yes (CORE FEATURE)
│  ├─ Need persistent workspaces?
│  │  ├─ Yes (CORE FEATURE)
│  │  │  ├─ Need dynamic networking?
│  │  │  │  ├─ Yes (Tailscale, WeTTY)
│  │  │  │  │  └─ ✅ Docker + Sysbox ONLY viable option
│  │  │  │  └─ No
│  │  │  │     └─ ⚠️ Kata (if accept 2-4x slower)
│  │  │  └─ No
│  │  │     └─ ❌ Not Sandcastle use case
│  │  └─ No (ephemeral)
│  │     └─ ⚠️ gVisor or Firecracker
│  └─ No
│     └─ ❌ Not Sandcastle use case
└─ No
   └─ ❌ Not Sandcastle use case
```

**Result:** Docker + Sysbox is the only technology that satisfies all three core requirements.

---

## Conclusion

After comprehensive research of five isolation technologies, **Docker + Sysbox remains the clear choice** for Sandcastle.

### Key Findings

1. **All alternatives have critical blockers:**
   - Firecracker: No filesystem sharing
   - Flintlock: No nested virtualization support
   - gVisor: Ephemeral Docker-in-Docker only
   - Kata: 2-4x slower Docker-in-Docker performance

2. **Docker-in-Docker is Sandcastle's core differentiator**, and only Sysbox is optimized for this use case

3. **Security trade-offs are acceptable** for the target use case (trusted-but-isolated developer sandboxes)

4. **Migration risks are high** with no clear benefits

5. **Sysbox has Docker corporate backing** ensuring continued maintenance

### Final Recommendation

**✅ Keep Docker + Sysbox as the primary isolation technology.**

**Monitor for future improvements:**
- Firecracker adds filesystem sharing
- Kata optimizes Docker-in-Docker performance
- gVisor supports persistent Docker workloads
- New technologies emerge

**Re-evaluate only if:**
- Major security incident affecting Sysbox
- Compliance requirements change
- Customer demand for hardware isolation tier
- Better Docker-in-Docker alternative emerges

---

## References

### Primary Research Documents
- [research/docker-sysbox.md](/research/docker-sysbox.md) — Current baseline solution
- [research/firecracker.md](/research/firecracker.md) — AWS Firecracker microVMs
- [research/flintlock.md](/research/flintlock.md) — Liquid Metal Flintlock
- [research/gvisor.md](/research/gvisor.md) — Google gVisor
- [research/kata-containers.md](/research/kata-containers.md) — Kata Containers

### External Resources
- [GitHub Issue #17](https://github.com/thieso2/Sandcastle/issues/17) — Firecracker research
- [Nestybox Sysbox Documentation](https://github.com/nestybox/sysbox)
- [Firecracker Official Documentation](https://firecracker-microvm.github.io/)
- [gVisor Architecture Guide](https://gvisor.dev/docs/architecture_guide/)
- [Kata Containers Documentation](https://katacontainers.io/)
- [Flintlock GitHub Repository](https://github.com/liquidmetal-dev/flintlock)

---

**Report Created:** February 13, 2026
**Research Conducted By:** Claude Sonnet 4.5 via parallel specialized agents
**Total Research Time:** 5 agents × 200-270 seconds = ~20 minutes
**Documents Generated:** 6 (this comparison + 5 technology-specific reports)
