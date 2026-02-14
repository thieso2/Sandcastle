# gVisor Research for Sandcastle

## Executive Summary

gVisor is a userspace kernel and OCI runtime that provides strong container isolation by intercepting system calls before they reach the host kernel. For Sandcastle's use case of providing isolated Docker-in-Docker sandboxes, **gVisor has significant limitations** that make it unsuitable as a replacement for Sysbox:

**Critical Blockers:**
- Docker-in-Docker requires tmpfs-only upper layers (no persistent overlay modifications)
- Performance overhead on I/O and network-heavy workloads (10x+ syscall overhead on KVM)
- Limited syscall compatibility (274/350 syscalls implemented)
- No support for nested hardware virtualization needed in some cloud environments
- Checkpoint/restore doesn't support live network connections

**Recommendation:** Sysbox remains the better choice for Sandcastle's VM-like container requirements with Docker-in-Docker and persistent workspaces.

---

## 1. What is gVisor?

gVisor is an application kernel that implements a Linux-like interface and provides strong container isolation by running a userspace kernel written in Go. Unlike traditional containers that share the host kernel, gVisor intercepts system calls and processes them through the "Sentry" (its userspace kernel) before selectively allowing a minimal subset to reach the host.

**Key Components:**
- **Sentry**: Userspace application kernel written in Go that handles syscalls, I/O routing, memory management
- **runsc**: OCI-compliant runtime (drop-in replacement for runc)
- **Gofer**: Filesystem proxy that mediates access to host files
- **Platform Syscall Switcher**: Intercepts syscalls using ptrace, KVM, or seccomp (systrap)

**Architecture:**
```
Application → System Call → Sentry (userspace kernel) → Gofer/Host → Host Kernel
                              ↓
                         Limited syscalls only
```

Sources: [gVisor Official Docs](https://gvisor.dev/docs/), [Introduction to gVisor Security](https://gvisor.dev/docs/architecture_guide/intro/)

---

## 2. Isolation Model

### Security Approach

gVisor reduces the attack surface by limiting which syscalls can reach the host kernel. Instead of hundreds of syscalls exposed to containers, gVisor provides:

- **274/350 syscalls** implemented for amd64 (full or partial)
- Syscalls processed by Go code (memory-safe language)
- Seccomp filtering on the limited syscalls that do reach the host
- Non-privileged userspace execution

**Isolation Strength Comparison:**

| Technology | Isolation Mechanism | Strength |
|------------|---------------------|----------|
| **Standard Containers** | Linux namespaces + cgroups | Weakest (shared kernel) |
| **Sysbox** | User namespaces (rootless) + advanced OS virtualization | Medium-Strong |
| **gVisor** | Userspace kernel + syscall interception | Strong |
| **VMs (Kata/Firecracker)** | Hardware virtualization | Strongest |

gVisor sits between Sysbox and VMs: stronger than namespace-based isolation but without the overhead of full virtualization.

**Key Security Finding:**
> "While Sysbox hardens the isolation of standard containers, it does not (yet) provide the same level of isolation as VM-based alternatives or user-space OSes like gVisor."

Source: [Sysbox vs gVisor Comparison](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)

### Container Escape Protection

gVisor has a strong track record against container escape vulnerabilities:

**CVE-2020-14386 Case Study:**
- Container escape vulnerability in Linux kernel
- gVisor was **not vulnerable** due to multiple layers:
  - Non-privileged user execution
  - CAP_NET_RAW capability not granted
  - Seccomp filters blocking the attack vector

**Security Philosophy:**
> "gVisor generally only assigns CVEs for issues that go beyond the sandbox boundary, since its main security focus is on preventing a user workload from 'getting out of the box'."

**Recent Vulnerability:**
CVE-2025-23266 (NVIDIAScape) did impact gVisor, allowing host files to be mounted into sandboxed containers. This shows that while gVisor significantly reduces risk, it's not immune to all escape vectors.

Sources: [CVE-2020-14386 Analysis](https://cloud.google.com/blog/products/containers-kubernetes/how-gvisor-protects-google-cloud-services-from-cve-2020-14386), [gVisor Security Blog](https://gvisor.dev/blog/2020/09/18/containing-a-real-vulnerability/)

---

## 3. Docker-in-Docker Support

### Current Status

gVisor **supports Docker-in-Docker** but with significant limitations:

**Requirements:**
- Must mount tmpfs at `/var/lib/docker`
- gVisor only allows tmpfs mounts as upper layers of overlay filesystems
- This means Docker container changes are **not persistent** across container restarts

**Working Configuration:**
```bash
docker run --runtime=runsc -v /var/lib/docker:tmpfs my-sandbox
# Docker works but changes are lost on container restart
```

**Why This Matters for Sandcastle:**
Sandcastle relies on persistent workspaces at `/data/sandboxes/{name}/vol:/workspace` where users store code, data, and Docker images/containers. With gVisor's tmpfs requirement, **all Docker state would be ephemeral**.

### Nested gVisor Limitation

Running gVisor inside a Docker container (nested gVisor) is **not supported**:
> "Running gVisor inside a Docker container isn't a well-supported use-case. Users have encountered issues when trying to run gVisor inside Docker containers."

The recommended workaround is mounting the host Docker socket, which bypasses isolation entirely.

**Impact:**
Sandcastle containers need to run their own isolated Docker daemon (true DinD), not just access the host daemon. This makes nested gVisor infeasible.

Sources: [Docker in gVisor Tutorial](https://gvisor.dev/docs/tutorials/docker-in-gvisor/), [gVisor Users Discussion](https://groups.google.com/g/gvisor-users/c/1NLhf1R8HVk)

---

## 4. OCI Runtime Compatibility

gVisor provides **runsc**, an OCI-compliant runtime that integrates with Docker and containerd.

### Docker Integration

```json
// /etc/docker/daemon.json
{
  "runtimes": {
    "runsc": {
      "path": "/usr/local/bin/runsc",
      "runtimeArgs": ["--platform=systrap"]
    }
  }
}
```

Usage:
```bash
docker run --runtime=runsc ubuntu:latest
```

**Compatibility:**
- Drop-in replacement for runc
- Works with existing Docker commands
- Supports host and bridge network drivers
- Docker 28+ requires AF_PACKET socket support (recently added)

**Limitations:**
- Not all Docker features work identically (e.g., overlay filesystem restrictions)
- Port forwarding in nested containers can be counter-intuitive
- Runtime switching requires daemon reconfiguration

Source: [Docker Quick Start](https://gvisor.dev/docs/user_guide/quick_start/docker/)

---

## 5. SSH, Networking, and Port Binding

### Networking Support

gVisor supports:
- **Host networking** (`--network=host`)
- **Bridge networking** (Docker bridge driver)
- Port forwarding via `-p` flags

**SSH Access:**
Standard SSH works in gVisor containers. Since SSH is just a network service listening on a port, gVisor's userspace network stack handles it transparently.

**For Sandcastle:**
```bash
# This should work
docker run --runtime=runsc -p 2201:22 sandcastle-image
ssh user@localhost -p 2201
```

### Known Networking Issues

- **inotify** doesn't work for bind-mounted files
- **Unix socket mounting** not fully supported
- Port forwarding in Docker-in-Docker scenarios can reference host paths unexpectedly

**Performance:**
Network-heavy workloads see degraded performance due to userspace network stack overhead.

Sources: [gVisor Networking](https://gvisor.dev/docs/user_guide/networking/), [Filesystem Limitations](https://gvisor.dev/docs/user_guide/filesystem/)

---

## 6. Bind Mounts and Volumes

### Support Matrix

| Mount Type | Supported | Notes |
|------------|-----------|-------|
| Bind mounts | ✅ Yes | Host directories mounted into container |
| tmpfs | ✅ Yes | In-memory filesystem |
| Volumes | ✅ Yes | Docker-managed volumes |
| Overlay upper (non-tmpfs) | ❌ No | **Critical limitation** |
| Unix sockets | ⚠️ Limited | Gofer doesn't support mounting sockets |

**Configuration:**
```bash
docker run --runtime=runsc \
  -v /host/path:/container/path \  # Works
  -v /tmpfs/path:/container/tmpfs \ # Works
  my-container
```

### Overlay Filesystem Optimization

gVisor recently added **rootfs overlay** by default:
- Overlays container rootfs with tmpfs (upper layer)
- Read-only lower layer served by Gofer
- **Halved filesystem overhead** for many workloads

This is an internal optimization for the container's root filesystem, not for Docker-in-Docker layers.

**For Sandcastle:**
Bind mounts for user home directories (`/data/users/{name}/home`) should work without issues. However, the Docker-in-Docker tmpfs requirement remains a blocker.

Sources: [Filesystem Documentation](https://gvisor.dev/docs/user_guide/filesystem/), [Rootfs Overlay Blog](https://opensource.googleblog.com/2023/04/gvisor-improves-performance-with-root-filesystem-overlay.html)

---

## 7. Snapshot and Restore Capability

### Checkpoint/Restore Support

gVisor has **built-in checkpoint/restore** functionality:

**Capabilities:**
- Save container state to disk
- Restore into a new container
- Use cases: caching warmed-up services, forensics, migration

**How It Works:**
```bash
# Checkpoint
runsc checkpoint --image-path=/tmp/checkpoint <container-id>

# Restore
runsc create <new-container-id>
runsc restore --image-path=/tmp/checkpoint <new-container-id>
```

**Architecture:**
gVisor controls the entire userspace kernel state, allowing complete process snapshots. The kernel.go file and 18+ system components implement save_restore.go files for comprehensive state capture.

### Limitations

**Critical for Sandcastle:**
1. **No live network connections**: TCP sockets are not preserved
2. **No GPU state**: NVIDIA GPU state not saved
3. **Single container only**: Multi-container setups not supported

**Comparison to Docker Commit:**
Sandcastle currently uses `docker commit` for snapshots, which creates image layers but doesn't preserve:
- Running process state
- In-memory data
- Network connections

gVisor's checkpoint/restore is more comprehensive than `docker commit` but incompatible with Docker's image format.

**Impact:**
For Sandcastle's snapshot feature, gVisor would require switching from Docker's native snapshot mechanism to runsc's checkpoint/restore API, breaking compatibility with Docker images.

Sources: [Checkpoint/Restore Documentation](https://gvisor.dev/docs/user_guide/checkpoint_restore/), [Modal's Memory Snapshots Blog](https://modal.com/blog/mem-snapshots)

---

## 8. Performance Analysis

### Syscall Overhead

**Platform Comparison:**

| Platform | Syscall Interception Method | Overhead |
|----------|----------------------------|----------|
| **Systrap** (default) | seccomp SECCOMP_RET_TRAP | Moderate |
| **KVM** | Hardware virtualization | **10x+ vs native** |
| **Ptrace** | Linux ptrace API | High (deprecated) |

**Key Finding:**
> "For KVM platform, the syscall interception costs more than 10x than a native Linux syscall."

**Real-World Impact:**
- **70% of applications**: <1% overhead
- **25% of applications**: <3% overhead
- **I/O and network-heavy**: Significant degradation

### Workload-Specific Performance

**CPU-Bound Workloads:**
> "gVisor does not perform emulation or otherwise interfere with the raw execution of CPU instructions by the application. Therefore, there is no runtime cost imposed for CPU operations."

**I/O-Heavy Workloads:**
Databases and file-intensive applications see the most overhead due to:
- Gofer RPC costs (filesystem proxy)
- Userspace network stack
- System call interception

**Example - LevelDB:**
Databases like LevelDB are especially impacted because they're bottlenecked on networking and file I/O.

### Recent Optimizations

**Directfs (2023):**
- Gives Sentry direct access to container filesystem
- Avoids expensive Gofer round trips
- **12% reduction** in workload execution time
- **17% reduction** in Ruby load time

**Rootfs Overlay (2023):**
- Overlays rootfs with tmpfs
- Halved sandboxing overhead for abseil builds

**For Sandcastle:**
SSH, shell sessions, and code editing should see minimal overhead. However, Docker builds, image pulls, and container I/O within sandboxes would see measurable performance degradation.

Sources: [Performance Guide](https://gvisor.dev/docs/architecture_guide/performance/), [Directfs Blog](https://opensource.googleblog.com/2023/06/optimizing-gvisor-filesystems-with-directfs.html)

---

## 9. Production Readiness

### Large-Scale Deployments

**Google Cloud:**
- **Cloud Run** (1st gen): Uses gVisor by default
- **App Engine**: Uses gVisor
- **Cloud Functions**: Uses gVisor
- **GKE Sandbox**: gVisor-based pod isolation

**Performance at Scale:**
- LISAFS rollout improved **App Engine cold start by >25%**
- Cloud Run scales to **1000 container instances** per service
- Each instance handles **250 simultaneous requests**

**Other Production Users:**
- **Ant Group**: 100K+ gVisor instances in production (Singles Day festival workloads)

### Production Guidance

**Recommended Use Cases:**
- CPU-bound API servers
- Non-static web servers
- Data pipelines
- Untrusted code execution (AI agents, sandboxing)

**Not Recommended:**
- Databases (I/O bottleneck)
- Load balancers (network overhead)
- Real-time high-throughput systems

**For Sandcastle:**
Mixed workload suitability:
- ✅ SSH sessions, terminal access, code editing
- ⚠️ Docker builds, image management (I/O overhead)
- ❌ Persistent Docker-in-Docker (tmpfs limitation)

Sources: [Production Guide](https://gvisor.dev/docs/user_guide/production/), [Cloud Run Documentation](https://cloud.google.com/blog/products/containers-kubernetes/gvisor-file-system-improvements-for-gke-and-serverless), [Ant Group Case Study](https://gvisor.dev/blog/2021/12/02/running-gvisor-in-production-at-scale-in-ant/)

---

## 10. Known Issues and Bugs

### Compatibility Gaps

**Kernel Subsystems:**
- **cgroups**: Resource accounting works, but **limits not enforced** within sandbox
  - Workaround: Place gVisor sandbox in host-level cgroup
- **Block devices**: fat32, ext3, ext4 not supported
- **io_uring**: Not fully supported (most libraries fall back automatically)
- **KVM access**: Cannot use hardware virtualization from within gVisor

**Filesystem:**
- **inotify**: Doesn't work for bind-mounted files
- **Unix sockets**: Gofer doesn't support mounting sockets
- **Overlay upper layers**: Must be tmpfs (critical for Docker-in-Docker)

### Syscall Compatibility

**Status:**
- 274/350 syscalls implemented (78%)
- Partial implementations may lack edge cases
- Most language runtimes have fallback mechanisms

**Regression Testing:**
gVisor releases are tested against:
- Python
- Java
- Node.js
- PHP
- Go

**For Sandcastle:**
Most developer tools should work, but edge cases may arise with:
- Advanced Docker features
- Low-level system tools
- Custom kernel modules (impossible in userspace kernel)

Sources: [Applications Compatibility](https://gvisor.dev/docs/user_guide/compatibility/), [Linux/amd64 Syscall Status](https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/)

---

## 11. gVisor vs Sysbox Comparison

### Architecture Philosophy

| Aspect | Sysbox | gVisor |
|--------|--------|--------|
| **Isolation** | User namespaces (rootless containers) | Userspace kernel + syscall interception |
| **Kernel** | Shared host kernel | Virtual kernel per container |
| **Performance** | Near-native (minimal overhead) | 1-10% overhead (workload-dependent) |
| **DinD** | Full persistent Docker-in-Docker | DinD with tmpfs limitation |
| **Syscalls** | All syscalls available | 274/350 syscalls |
| **Use Case** | VM-like containers | Untrusted code sandboxing |

### Security Trade-offs

**Sysbox:**
- ✅ Strong isolation via user namespaces
- ✅ Rootless containers
- ⚠️ Still shares host kernel (attack surface exists)

**gVisor:**
- ✅ Reduced attack surface (minimal syscalls to host)
- ✅ Memory-safe Go kernel
- ⚠️ Higher overhead
- ⚠️ Compatibility limitations

**Expert Opinion:**
> "If you wish to reduce the attack surface between containerized apps and the Linux kernel without VMs, gVisor is appropriate, while if you wish to run 'VM-like' containers with strong isolation via the Linux user namespace (i.e., rootless), Sysbox is more appropriate."

### Performance Comparison

**Syscall Overhead:**
- Sysbox: Near-native (direct to host kernel)
- gVisor: 10x overhead (KVM platform)

**I/O Performance:**
- Sysbox: Native filesystem performance
- gVisor: Gofer proxy overhead (mitigated by Directfs)

**Network Performance:**
- Sysbox: Native network stack
- gVisor: Userspace network stack overhead

### Hardware Requirements

**Sysbox:**
- No special requirements
- Works in nested cloud environments without hardware virtualization

**gVisor:**
- KVM platform requires hardware virtualization support
- Systrap platform (default) works without virtualization
- May struggle in nested virtualization scenarios

Source: [Sysbox vs Related Tech Comparison](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)

---

## 12. Application Compatibility

### Language Runtime Support

gVisor is tested against major language runtimes:

| Runtime | Support | Notes |
|---------|---------|-------|
| Python | ✅ Full | Regression tested every release |
| Java | ✅ Full | Regression tested every release |
| Node.js | ✅ Full | Regression tested every release |
| PHP | ✅ Full | Regression tested every release |
| Go | ✅ Full | Regression tested every release |
| Rust | ⚠️ Mostly | Some low-level crates may have issues |

### Common Developer Tools

**Expected to Work:**
- Git
- SSH/SSHD
- tmux/screen
- vim/emacs/nano
- Package managers (apt, pip, npm, cargo)
- Compilers (gcc, clang, rustc, go)

**May Have Issues:**
- Docker-in-Docker (tmpfs limitation)
- Low-level debuggers (gdb, strace)
- Kernel modules (impossible)
- Custom hardware access
- io_uring-dependent tools

### Docker Compatibility

**Working Docker Features:**
- `docker run`
- `docker build`
- `docker pull/push`
- Bridge networking
- Host networking
- Port forwarding

**Limited Docker Features:**
- Persistent overlay layers (tmpfs only)
- Nested gVisor containers
- Docker volumes on block devices
- Some advanced networking modes

**For Sandcastle Users:**
Developers working in Sandcastle sandboxes would experience:
- ✅ Normal shell/terminal work
- ✅ Code editing, Git operations
- ✅ Building and running applications
- ⚠️ Docker builds (slower, tmpfs-only)
- ❌ Persistent Docker state across restarts

---

## 13. Recommendations for Sandcastle

### Pros of gVisor

1. **Stronger Isolation**: Reduced attack surface compared to Sysbox
2. **Memory Safety**: Go-based kernel reduces vulnerability risk
3. **Production Proven**: Used at scale by Google Cloud services
4. **OCI Compatible**: Drop-in replacement for runc
5. **Checkpoint/Restore**: Advanced state snapshotting capability
6. **Active Development**: Continuous performance improvements (Directfs, rootfs overlay)

### Cons of gVisor (Critical for Sandcastle)

1. **Docker-in-Docker Limitation**: tmpfs-only requirement breaks persistent workspaces
2. **Performance Overhead**: I/O and network-heavy Docker operations see degradation
3. **Syscall Compatibility**: 78% implementation may cause edge-case failures
4. **No Nested gVisor**: Can't run gVisor sandboxes within gVisor
5. **Checkpoint Network Limitation**: Can't preserve TCP connections during snapshot
6. **Complexity**: Additional layer adds operational overhead

### Decision Matrix

| Sandcastle Requirement | Sysbox | gVisor |
|------------------------|--------|--------|
| Docker-in-Docker (persistent) | ✅ Full support | ❌ tmpfs only |
| SSH access | ✅ Native | ✅ Works |
| Port binding | ✅ Native | ✅ Works |
| Bind mounts | ✅ Full support | ✅ Works |
| Snapshot/restore | ⚠️ Docker commit | ⚠️ No network state |
| Performance | ✅ Near-native | ⚠️ 1-10% overhead |
| Isolation strength | ⚠️ User namespaces | ✅ Userspace kernel |
| Syscall compatibility | ✅ 100% | ⚠️ 78% |
| Production readiness | ✅ Mature | ✅ Proven at scale |

### Final Recommendation

**Keep Sysbox** for Sandcastle's current architecture because:

1. **Persistent Docker-in-Docker is non-negotiable**: Users need their Docker images, containers, and volumes to survive sandbox restarts
2. **Performance matters**: Docker builds and container I/O are core workflows
3. **VM-like UX**: Sandcastle positions itself as "containers that feel like VMs"
4. **Compatibility**: Full syscall support reduces edge-case failures

**When gVisor Makes Sense:**

If Sandcastle pivots to one of these models, reconsider gVisor:
- **Ephemeral sandboxes**: Short-lived execution (like Cloud Run)
- **Code execution only**: No Docker-in-Docker required
- **Untrusted code**: Maximum isolation for arbitrary user code
- **Serverless model**: Fast cold starts with checkpoint/restore

### Hybrid Approach (Future)

Consider offering both runtimes:
```yaml
# User chooses isolation level
sandbox:
  name: my-sandbox
  runtime: sysbox  # or gvisor
```

**Trade-offs:**
- Sysbox: Performance + full Docker, moderate isolation
- gVisor: Strong isolation, limited Docker, overhead

This gives users the choice between "VM-like flexibility" (Sysbox) and "maximum security" (gVisor).

---

## 14. Further Reading

### Official Documentation
- [gVisor Official Site](https://gvisor.dev)
- [gVisor GitHub Repository](https://github.com/google/gvisor)
- [Architecture Guide](https://gvisor.dev/docs/architecture_guide/intro/)
- [Security Model](https://gvisor.dev/docs/architecture_guide/security/)
- [Performance Guide](https://gvisor.dev/docs/architecture_guide/performance/)

### Key Blog Posts
- [Rootfs Overlay Performance](https://opensource.googleblog.com/2023/04/gvisor-improves-performance-with-root-filesystem-overlay.html)
- [Directfs Optimization](https://opensource.googleblog.com/2023/06/optimizing-gvisor-filesystems-with-directfs.html)
- [Running gVisor at Scale (Ant Group)](https://gvisor.dev/blog/2021/12/02/running-gvisor-in-production-at-scale-in-ant/)
- [CVE-2020-14386 Container Escape Analysis](https://cloud.google.com/blog/products/containers-kubernetes/how-gvisor-protects-google-cloud-services-from-cve-2020-14386)

### Comparisons and Analyses
- [Sysbox vs Related Technologies](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)
- [Sandboxing AI Agents (2026)](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [Container Security Comparison](https://www.cloudnative.quest/posts/security/2022-02-09/sandboxing-containers/)
- [GKE Sandbox (gVisor) Isolation](https://oneuptime.com/blog/post/2026-02-09-gke-sandbox-gvisor-workload-isolation/view)

### Tutorials and Guides
- [Docker Quick Start](https://gvisor.dev/docs/user_guide/quick_start/docker/)
- [Docker in gVisor](https://gvisor.dev/docs/tutorials/docker-in-gvisor/)
- [Checkpoint/Restore Guide](https://gvisor.dev/docs/user_guide/checkpoint_restore/)

---

## Appendix: Technical Deep Dives

### Platform Syscall Interceptor Mechanisms

**Systrap (Default):**
- Uses seccomp's SECCOMP_RET_TRAP
- Kernel sends SIGSYS to application thread
- gVisor handles syscall in userspace
- Lower overhead than ptrace
- No hardware virtualization required

**KVM:**
- Uses kernel KVM functionality
- Sentry acts as both guest OS and VMM
- Hardware virtualization extensions required
- Lowest syscall interception overhead
- Poor nested virtualization support

**Ptrace (Deprecated):**
- Linux ptrace API
- Highest overhead
- No longer recommended

### Gofer Filesystem Proxy

The Gofer mediates all filesystem access between the Sentry and host:

```
Application → Sentry → Gofer → Host Filesystem
```

**LISAFS Protocol:**
- Purpose-built RPC protocol
- Replaced older 9P protocol
- 25%+ cold start improvement in App Engine

**Directfs Optimization:**
- Sentry gets direct access to container rootfs
- Bypasses Gofer for many operations
- 12% workload time reduction
- 17% Ruby load time reduction

### Memory and CPU Overhead

**Memory:**
- Each gVisor container needs its own Sentry process
- ~30-50MB overhead per sandbox
- Shared libraries reduce per-container cost

**CPU:**
- No emulation (native instruction execution)
- Overhead comes from syscall interception
- Context switches between app and Sentry
- Go garbage collection in Sentry

### Network Stack

gVisor implements a userspace TCP/IP stack:

**Components:**
- Netstack: Go-based TCP/IP implementation
- Sentry handles all network syscalls
- Host networking bypasses Netstack

**Overhead Sources:**
- Packet processing in userspace
- Context switches for network I/O
- Go garbage collection

**Optimization:**
Use `--network=host` for network-heavy workloads to bypass Netstack entirely.

---

## Revision History

- **2026-02-13**: Initial research document created based on official documentation, production case studies, and community discussions
