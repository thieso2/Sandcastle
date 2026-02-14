# Firecracker MicroVM Research for Sandcastle

## Executive Summary

AWS Firecracker is a production-grade microVM technology that provides hardware-level isolation through KVM virtualization with near-container performance. While it offers significant security advantages over Docker + Sysbox, adopting Firecracker for Sandcastle would require substantial architectural changes and introduce significant operational complexity. **Recommendation: Not suitable for direct adoption, but worth monitoring for future consideration.**

## Overview

[Firecracker](https://firecracker-microvm.github.io/) is an open-source virtualization technology developed by Amazon Web Services that powers AWS Lambda and Fargate. It creates lightweight virtual machines (microVMs) that combine the security and isolation properties of hardware virtualization with near-container speed and density.

**Current Version:** v1.14.1 (January 2026)
**License:** Apache 2.0
**Language:** Rust
**Production Status:** Battle-tested at scale (handling trillions of requests monthly in AWS Lambda)

## Architecture

### Core Design

Firecracker runs in user space and uses Linux KVM to create microVMs. Each microVM is a true virtual machine with its own kernel, providing hardware-level isolation.

**Key characteristics:**
- Minimalist device model (only 5 emulated devices: virtio-net, virtio-block, virtio-vsock, serial console, minimal keyboard controller)
- Written in Rust for memory safety
- RESTful HTTP API over Unix socket for control
- Jailer process for additional process-level isolation
- Reduced attack surface compared to traditional hypervisors

### Performance Metrics

- **Boot time:** ≤125ms to Linux userspace
- **Creation rate:** Up to 150 microVMs/second/host
- **Memory overhead:** <5 MiB per microVM
- **Snapshot/restore:** 4-10ms restore time

Sources: [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker), [Firecracker documentation](https://firecracker-microvm.github.io/), [Snapshot support](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)

## Evaluation Against Sandcastle Requirements

### 1. Docker-in-Docker Support (Nested Virtualization)

**Status:** ⚠️ Possible but Complex

Firecracker CAN run Docker inside microVMs, but it requires:
- Guest kernel with Docker and containerd installed
- KVM access for the Firecracker host (nested virtualization if host is a VM)
- Proper kernel configuration in the guest image

**Implementation notes:**
- [BuildBuddy successfully runs Docker-in-Firecracker](https://www.buildbuddy.io/docs/rbe-microvms/) for remote build execution
- [firecracker-in-docker](https://github.com/fadams/firecracker-in-docker) demonstrates running Firecracker inside Docker containers
- The microVM must have a full init system (not just PID 1 as the workload) to properly initialize /proc, tempfs, hostname, etc.

**Verdict:** Achievable but adds complexity compared to Sysbox's native Docker-in-Docker support.

### 2. SSH Access to VMs

**Status:** ✅ Fully Supported

SSH access works like any Linux VM:
- Guest needs SSH server installed (e.g., openssh-server)
- TAP device provides network connectivity
- Can SSH directly to guest IP: `ssh root@172.17.0.21 -i key.pem`

**Network setup required:**
- Create TAP device per microVM
- Configure guest IP and routing
- Set up iptables for NAT and masquerading

Sources: [Firecracker networking guide](https://github.com/firecracker-microvm/firecracker/blob/main/docs/network-setup.md), [Networking tutorial](https://blog.0x74696d.com/posts/networking-firecracker-lab/)

**Verdict:** Works well, but requires more manual networking setup than Docker port bindings.

### 3. Port Binding and Networking

**Status:** ⚠️ Requires Manual Configuration

Unlike Docker's simple `-p` port binding, Firecracker networking requires:

**Per-microVM setup:**
- Create unique TAP device
- Assign unique IP subnet
- Configure iptables port forwarding rules: `iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 172.16.0.2:8080`
- Set up NAT masquerading

**Multiple networks:**
- Firecracker supports multiple network interfaces per microVM
- Each interface needs its own TAP device
- CNI plugins can help manage this: ptp, firewall, host-local, tc-redirect-tap

**Dynamic connections (like Tailscale):**
- Would require adding/removing network interfaces at runtime
- Firecracker does NOT support hot-plugging network interfaces after boot
- Workaround: Pre-attach all needed interfaces or restart the microVM

Sources: [firecracker-containerd networking](https://github.com/firecracker-microvm/firecracker-containerd/blob/main/docs/networking.md), [CNI plugins](https://gruchalski.com/posts/2021-02-07-vault-on-firecracker-with-cni-plugins-and-nomad/)

**Verdict:** Significantly more complex than Docker. Dynamic network reconfiguration (key for Sandcastle's Tailscale integration) is problematic.

### 4. Bind Mounts for Persistent Storage

**Status:** ❌ Major Limitation

**Current state:**
- Firecracker does NOT support virtio-fs or 9p filesystem sharing
- [Host filesystem sharing issue #1180](https://github.com/firecracker-microvm/firecracker/issues/1180) has been requested since 2019
- [Virtio-fs PR #1351](https://github.com/firecracker-microvm/firecracker/pull/1351) was closed due to security concerns (large attack surface)

**Available workarounds:**
- **virtio-block devices:** Attach raw block devices or loop devices from host
  - Requires pre-creating filesystems
  - Not suitable for shared `/home` directories across sandboxes
  - File-level sharing not possible
- **Network filesystems:** NFS, 9p over virtio-vsock (requires custom setup)
- **Rebuild root filesystem:** Bake user data into guest images (slow, inflexible)

**Impact on Sandcastle:**
- Cannot bind-mount `/data/users/{name}/home` into microVMs
- Cannot bind-mount `/data/sandboxes/{name}/vol:/workspace`
- Would need to use virtio-block devices, sacrificing flexibility
- Sharing a home directory across multiple sandboxes for the same user becomes very difficult

**Verdict:** This is a **critical blocker** for Sandcastle's current architecture. The ability to share host filesystems is fundamental to how user homes and workspace volumes work today.

### 5. Snapshot/Restore Capability

**Status:** ✅ Excellent

Firecracker has production-grade snapshot support:

**Full snapshots:**
- Create snapshot via API: `PUT /snapshot/create`
- Includes memory state and device state
- Restore in 4-10ms for typical workloads

**Diff snapshots:**
- Incremental snapshots (developer preview)
- Only save changed memory pages

**Memory mapping:**
- Uses MAP_PRIVATE with on-demand loading
- Very fast restoration
- Guest memory file must remain available during microVM lifetime

**Caveats:**
- Recommended to use cgroups v2 for best performance
- Snapshot versioning across Firecracker releases requires attention

Sources: [Snapshot support docs](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md), [Firebench paper](https://dreadl0ck.net/papers/Firebench.pdf)

**Verdict:** Superior to Docker's `docker commit`. Faster restoration and true full-state snapshots.

### 6. Security Isolation Strength

**Status:** ✅ Superior to Sysbox

**Firecracker advantages:**
- Hardware-level isolation via KVM (separate kernel per microVM)
- Even kernel exploits in guest cannot escape to host
- Minimal device model reduces attack surface
- Rust memory safety prevents VMM vulnerabilities
- Seccomp filters per thread
- Jailer process for additional user-space isolation

**Sysbox limitations:**
- Shared kernel with host (user namespace isolation only)
- Kernel vulnerabilities affect all containers
- Larger attack surface

**Industry consensus (2026):**
- [Firecracker recommended for untrusted AI code](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [Hardware-enforced boundaries prevent kernel exploits](https://manveerc.substack.com/p/ai-agent-sandboxing-guide)
- [Sysbox provides weaker isolation than Firecracker](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)

Sources: [Firecracker vs Docker security](https://huggingface.co/blog/agentbox-master/firecracker-vs-docker-tech-boundary), [2026 sandboxing guide](https://northflank.com/blog/how-to-sandbox-ai-agents)

**Verdict:** Firecracker provides significantly stronger isolation, crucial for multi-tenant environments with untrusted code.

### 7. Performance

**Status:** ✅ Excellent (but trade-offs exist)

**Startup time:**
- Firecracker: ~125ms (minimal kernel) to ~800-1000ms (full Linux)
- Docker + Sysbox: ~2-5s (includes Docker layer setup)
- **Winner:** Firecracker (2-4x faster)

**Memory overhead:**
- Firecracker: <5 MiB per microVM + guest kernel/userspace
- Docker: Minimal (shared kernel)
- **Trade-off:** Firecracker needs guest OS memory (typically 128+ MiB)

**CPU overhead:**
- Firecracker: Minimal (hardware virtualization)
- Docker: Minimal (native)
- **Roughly equivalent** for most workloads

**Density:**
- Firecracker: Supports thousands of microVMs per host
- Docker: Supports thousands of containers per host
- **Roughly equivalent** (memory is the limiting factor)

Sources: [Firecracker performance specs](https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md), [Firebench study](https://dreadl0ck.net/papers/Firebench.pdf)

**Verdict:** Faster boot, slightly higher memory per instance. Overall excellent performance.

### 8. API Maturity and Ease of Use

**Status:** ⚠️ Low-Level, Requires Abstraction

**API characteristics:**
- RESTful HTTP API over Unix socket
- Well-documented but low-level
- Requires manual management of:
  - TAP device creation
  - Kernel and rootfs images
  - Network configuration
  - IP address allocation
  - iptables rules

**Ruby integration:**
- No official Ruby SDK
- Go SDK exists: [firecracker-go-sdk](https://github.com/firecracker-microvm/firecracker-go-sdk)
- Can use any Ruby HTTP client (Faraday, HTTParty) to call API
- Would need to build Ruby wrapper from scratch

**Example API calls:**
```bash
# Configure boot source
curl --unix-socket /tmp/firecracker.socket -i \
  -X PUT 'http://localhost/boot-source' \
  -H 'Content-Type: application/json' \
  -d '{
    "kernel_image_path": "/path/to/kernel",
    "boot_args": "console=ttyS0"
  }'

# Add network interface
curl --unix-socket /tmp/firecracker.socket -i \
  -X PUT 'http://localhost/network-interfaces/eth0' \
  -H 'Content-Type: application/json' \
  -d '{
    "iface_id": "eth0",
    "host_dev_name": "tap0",
    "guest_mac": "AA:FC:00:00:00:01"
  }'

# Start microVM
curl --unix-socket /tmp/firecracker.socket -i \
  -X PUT 'http://localhost/actions' \
  -H 'Content-Type: application/json' \
  -d '{"action_type": "InstanceStart"}'
```

Sources: [Firecracker API tutorial](https://jvns.ca/blog/2021/01/23/firecracker--start-a-vm-in-less-than-a-second/), [Go SDK](https://github.com/firecracker-microvm/firecracker-go-sdk)

**Verdict:** API is mature but low-level. Significantly more complex than `docker-api` gem. Would require substantial custom Ruby code.

### 9. Operational Complexity

**Status:** ⚠️ High (without orchestration)

**Manual setup required:**
1. **Kernel images:** Build or maintain minimal kernels per microVM
2. **Rootfs images:** Create and manage guest filesystems
3. **TAP devices:** Create/destroy per microVM, configure routing
4. **IP allocation:** Manage IP subnets to avoid conflicts
5. **iptables rules:** Configure NAT and port forwarding
6. **Jailer setup:** Configure seccomp, cgroups, namespaces
7. **Process management:** Each microVM is a separate process
8. **Cleanup:** Properly tear down TAP devices, iptables rules, processes

**Docker comparison:**
- Docker: `docker run` handles all of the above
- Firecracker: Manual management or custom orchestration

**Orchestration options:**
- [Kata Containers](https://katacontainers.io/): Production-ready Kubernetes integration
  - Abstracts Firecracker/Cloud Hypervisor/QEMU behind CRI
  - Handles networking, storage, lifecycle
  - Recommended path for Kubernetes workloads
- [firecracker-containerd](https://github.com/firecracker-microvm/firecracker-containerd): containerd plugin
  - Integrates Firecracker with containerd
  - Less mature than Kata
- [Ignite](https://github.com/weaveworks/ignite): Weaveworks tool (archived)
  - Combined Firecracker with Docker UX
  - No longer actively maintained

Sources: [Kata vs Firecracker comparison](https://northflank.com/blog/kata-containers-vs-firecracker-vs-gvisor), ["Please stop saying just use Firecracker"](https://some-natalie.dev/blog/stop-saying-just-use-firecracker/)

**Verdict:** Running Firecracker directly is complex. Kata Containers is recommended for production, but adds dependency. Docker + Sysbox is significantly simpler operationally.

### 10. Production Readiness and Ecosystem

**Status:** ✅ Battle-Tested

**Production deployments:**
- [AWS Lambda](https://aws.amazon.com/blogs/aws/firecracker-lightweight-virtualization-for-serverless-computing/): Trillions of requests monthly
- [AWS Fargate](https://www.amazon.science/blog/how-awss-firecracker-virtual-machines-work): Container orchestration
- [Fly.io](https://fly.io): Edge compute platform
- [BuildBuddy](https://www.buildbuddy.io/docs/rbe-microvms/): Remote build execution
- [E2B](https://e2b.dev/blog/firecracker-vs-qemu): Code execution sandbox (2026)

**Ecosystem maturity:**
- Active development (v1.14.1 as of January 2026)
- Large community (32k+ GitHub stars)
- Well-documented
- Security vulnerability tracking (e.g., CVE-2026-1386 jailer symlink issue)

**Known limitations (2026):**
- No GPU/PCIe passthrough support (by design)
- No hardware accelerator support
- No host filesystem sharing (virtio-fs rejected)
- Cannot hot-plug network interfaces
- Limited post-boot configuration changes
- Kata Containers doesn't apply CPU/memory limits correctly for Firecracker pods

Sources: [Production use cases](https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9), [Firecracker limitations](https://github.com/kata-containers/documentation/issues/351), [CVE-2026-1386](https://www.sentinelone.com/vulnerability-database/cve-2026-1386/)

**Verdict:** Proven at massive scale, but production use typically involves orchestration layers (Kata, custom tooling).

## Pros and Cons for Sandcastle

### Advantages

1. **Superior security isolation:** Hardware-level isolation prevents kernel exploits, critical for multi-tenant untrusted code execution
2. **Excellent snapshot/restore:** 4-10ms restore time with full memory state
3. **Fast boot times:** 125ms-1s vs 2-5s for Docker + Sysbox
4. **Production-proven:** Powers AWS Lambda, used by major platforms
5. **Future-oriented:** Industry trend toward microVMs for untrusted workloads (especially AI agents in 2026)
6. **Low memory overhead:** <5 MiB VMM overhead per instance

### Disadvantages

1. **❌ CRITICAL: No host filesystem sharing** — Cannot bind-mount user homes or workspace volumes. This is a fundamental blocker for Sandcastle's current architecture.
2. **⚠️ Complex networking:** Manual TAP device and iptables management vs simple Docker port bindings. Dynamic network changes (Tailscale) become very difficult.
3. **⚠️ High operational complexity:** Must manage kernels, rootfs images, TAP devices, IP allocation, iptables, jailer configuration
4. **⚠️ No Ruby SDK:** Would need to build custom API client from scratch
5. **⚠️ No hot-plug networking:** Cannot dynamically add/remove network interfaces (breaks Tailscale UX)
6. **Higher memory per instance:** Need full guest OS (128+ MiB) vs shared kernel
7. **Requires KVM:** Host must support hardware virtualization (nested virt if host is VM)

## Implementation Complexity Analysis

### Migration Effort: **VERY HIGH**

**Core changes required:**

1. **Storage architecture redesign:**
   - Replace bind mounts with virtio-block devices or network filesystems
   - Build system to manage block device allocation
   - Implement network filesystem server (NFS, custom 9p over vsock)
   - Rethink user home sharing across multiple sandboxes

2. **Networking layer rewrite:**
   - Build TAP device manager
   - Implement IP address allocation system
   - Create iptables rule management system
   - Redesign port binding to use DNAT rules
   - Rework Tailscale integration (possibly pre-attach interfaces or accept restart requirement)

3. **Image management:**
   - Build or maintain minimal guest kernels
   - Create rootfs image pipeline
   - Implement image versioning and updates
   - Handle SSH key injection at image/boot time

4. **API client development:**
   - Write Ruby wrapper for Firecracker HTTP API
   - Implement Unix socket communication
   - Handle API error states
   - Build abstraction matching current `docker-api` gem usage

5. **Orchestration layer:**
   - Replace `SandboxManager` entirely
   - Implement process management for microVM processes
   - Handle jailer configuration (seccomp, cgroups, namespaces)
   - Build lifecycle management (create, start, stop, snapshot, destroy)

6. **Service updates:**
   - `SandboxManager`: Complete rewrite
   - `TerminalManager`: Update for new networking model
   - `TailscaleManager`: Rethink architecture (network hot-plug not supported)
   - `SystemStatus`: Query Firecracker metrics instead of Docker API

**Estimated effort:** 8-12 weeks of full-time development + significant testing/debugging

### Alternative: Kata Containers

[Kata Containers](https://katacontainers.io/) provides a CRI-compatible layer that runs containers as microVMs:

**Advantages:**
- Compatible with existing container workflows
- Handles orchestration complexity
- Production-ready Kubernetes integration
- Supports multiple VMMs (Firecracker, Cloud Hypervisor, QEMU)

**Disadvantages:**
- Designed for Kubernetes, overkill for Sandcastle's simple use case
- Still inherits Firecracker's filesystem sharing limitations
- Known issues with Firecracker backend (CPU/memory limits don't work)
- Adds another dependency layer

**Verdict:** Not a good fit for Sandcastle's Rails-based architecture.

## Comparison Matrix

| Feature | Docker + Sysbox (Current) | Firecracker (Direct) | Firecracker + Kata |
|---------|---------------------------|----------------------|--------------------|
| Security Isolation | Kernel-level (user namespace) | Hardware-level (KVM) | Hardware-level (KVM) |
| Boot Time | 2-5s | 125ms-1s | 1-3s |
| Memory Overhead | Minimal | 5 MiB VMM + 128+ MiB guest OS | Similar to direct |
| Bind Mounts | ✅ Native | ❌ Not supported | ⚠️ Limited (via 9p) |
| Dynamic Networking | ✅ Docker networks | ❌ No hot-plug | ⚠️ Through CNI |
| Port Binding | ✅ Simple (`-p`) | ⚠️ Manual iptables | ⚠️ CNI managed |
| Snapshot/Restore | ⚠️ `docker commit` (slow) | ✅ Excellent (4-10ms) | ✅ Excellent |
| API Complexity | ✅ Ruby gem (`docker-api`) | ⚠️ Low-level REST (custom client needed) | ⚠️ CRI/gRPC |
| Operational Complexity | ✅ Low | ❌ High | ⚠️ Medium (K8s-oriented) |
| Docker-in-Docker | ✅ Native | ⚠️ Requires setup | ⚠️ Requires setup |
| Production Readiness | ✅ Stable | ✅ Battle-tested (AWS Lambda) | ✅ Stable |
| Ruby Ecosystem | ✅ `docker-api` gem | ❌ No SDK (HTTP client needed) | ❌ No Ruby CRI client |

## Recommendations

### Short Term (Next 6 Months): **Keep Docker + Sysbox**

**Reasoning:**
1. The **lack of host filesystem sharing** is a critical blocker
2. High migration complexity (8-12 weeks) for unclear benefits
3. Sandcastle's current Docker + Sysbox architecture works well
4. Sysbox provides good-enough isolation for current use case

**Recommendation:** Continue with Docker + Sysbox.

### Medium Term (6-18 Months): **Monitor Firecracker Development**

**Watch for:**
1. Virtio-fs implementation (unlikely given 2026 rejection, but security landscape may change)
2. Alternative filesystem sharing solutions (e.g., official 9p support, vsock-based filesystems)
3. Hot-plug networking support
4. Ruby SDK development (community or official)

**If these materialize:** Re-evaluate migration.

### Long Term (18+ Months): **Consider Hybrid Approach**

**Potential architecture:**
- Keep Docker + Sysbox for trusted/internal users
- Add Firecracker tier for high-security/untrusted workloads
- Offer as premium feature or for specific compliance needs

**Benefits:**
- Gradual migration path
- Leverage Firecracker's superior isolation where needed
- Lower risk than full replacement

### Alternative Consideration: gVisor

[gVisor](https://gvisor.dev/) is another sandboxing technology worth evaluating:

**Advantages over Firecracker:**
- Drop-in replacement for runc (Docker-compatible)
- Supports bind mounts natively
- No kernel/rootfs image management
- Lower operational complexity

**Disadvantages:**
- User-space kernel (not hardware isolation)
- Performance overhead (syscall interception)
- Less battle-tested than Firecracker at scale

**Verdict:** If security isolation becomes a critical concern, evaluate gVisor before Firecracker. It offers a better migration path from Docker.

## Conclusion

Firecracker is an excellent technology that provides superior security isolation and performance. However, for Sandcastle's specific needs, the **lack of host filesystem sharing is a critical blocker** that makes migration impractical without fundamental architecture changes.

The current Docker + Sysbox approach provides:
- ✅ Simple bind mount support (user homes, workspace volumes)
- ✅ Easy dynamic networking (Docker networks, Tailscale)
- ✅ Straightforward port binding
- ✅ Good-enough isolation for most use cases
- ✅ Low operational complexity
- ✅ Mature Ruby integration (`docker-api` gem)

**Final recommendation: Continue with Docker + Sysbox for now.** Monitor Firecracker's filesystem sharing developments and consider re-evaluation if:
1. Virtio-fs or alternative host sharing solution becomes available
2. Security requirements change (e.g., handling highly untrusted code, compliance needs)
3. A compelling business case emerges (e.g., premium security tier)

If stronger isolation becomes necessary in the medium term, evaluate **gVisor** as a more Docker-compatible alternative before committing to Firecracker's complexity.

## Sources

- [Firecracker GitHub Repository](https://github.com/firecracker-microvm/firecracker)
- [Firecracker Official Documentation](https://firecracker-microvm.github.io/)
- [Firecracker vs Docker: Technical Boundary](https://huggingface.co/blog/agentbox-master/firecracker-vs-docker-tech-boundary)
- [How to Sandbox AI Agents in 2026](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [AI Agent Sandboxing Guide 2026](https://manveerc.substack.com/p/ai-agent-sandboxing-guide)
- [Firecracker Networking Documentation](https://github.com/firecracker-microvm/firecracker-containerd/blob/main/docs/networking.md)
- [Firecracker Snapshot Support](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)
- [Host Filesystem Sharing Issue #1180](https://github.com/firecracker-microvm/firecracker/issues/1180)
- [Kata Containers vs Firecracker vs gVisor](https://northflank.com/blog/kata-containers-vs-firecracker-vs-gvisor)
- [Building Production-Grade Code Execution with Firecracker (2026)](https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9)
- [Please Stop Saying "Just Use Firecracker"](https://some-natalie.dev/blog/stop-saying-just-use-firecracker/)
- [Comparison: Sysbox and Related Technologies](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)
- [Firecracker Performance Benchmarks](https://dreadl0ck.net/papers/Firebench.pdf)
- [AWS Lambda Announcement](https://aws.amazon.com/blogs/aws/firecracker-lightweight-virtualization-for-serverless-computing/)
- [BuildBuddy RBE with Firecracker](https://www.buildbuddy.io/docs/rbe-microvms/)
- [CVE-2026-1386 Security Advisory](https://www.sentinelone.com/vulnerability-database/cve-2026-1386/)
