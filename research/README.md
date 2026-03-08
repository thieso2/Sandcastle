# Container Isolation Technology Research

**Date:** February 13, 2026
**Purpose:** Evaluate alternatives to Docker + Sysbox for Sandcastle sandboxes
**Related Issue:** [#17 - Research: Firecracker microVM as Docker alternative](https://github.com/thieso2/Sandcastle/issues/17)

---

## Executive Summary

**Recommendation: Keep Docker + Sysbox**

All evaluated alternatives have critical blockers that make them unsuitable for Sandcastle's Docker-in-Docker use case with persistent workspaces and dynamic networking.

| Technology | Status | Critical Blocker |
|------------|--------|------------------|
| **Docker + Sysbox** | ✅ Current solution | None |
| **Firecracker** | ❌ Not viable | No filesystem sharing support |
| **Flintlock** | ❌ Not viable | No nested virtualization support |
| **gVisor** | ❌ Not viable | Docker-in-Docker is ephemeral only |
| **Kata Containers** | ⚠️ Unsuitable | 2-4x slower Docker-in-Docker |

---

## Research Documents

### [COMPARISON.md](./COMPARISON.md) 📊
**Main comparison document** — Comprehensive analysis with:
- Executive summary
- Requirements matrix
- Detailed technology analysis (5 technologies)
- Performance, security, and operational comparisons
- Decision matrix and recommendations
- **Read this first for full context**

### Individual Technology Reports

1. **[docker-sysbox.md](./docker-sysbox.md)** 📦
   - Current baseline solution
   - Architecture and security model
   - Production experience (2+ years)
   - Known limitations and workarounds
   - 625 lines, 28KB

2. **[firecracker.md](./firecracker.md)** 🔥
   - AWS microVM technology
   - Hardware-level isolation
   - **BLOCKER:** No filesystem sharing
   - Used by AWS Lambda, Fly.io, E2B
   - 550+ lines

3. **[flintlock.md](./flintlock.md)** 🔩
   - Firecracker management layer
   - Kubernetes-on-bare-metal focus
   - **BLOCKER:** No nested virtualization
   - Community-led after Weaveworks shutdown
   - 450+ lines

4. **[gvisor.md](./gvisor.md)** 🛡️
   - Google userspace kernel
   - Syscall interception
   - **BLOCKER:** Ephemeral Docker-in-Docker
   - Used by Google Cloud Run, App Engine
   - 500+ lines

5. **[kata-containers.md](./kata-containers.md)** 📦🖥️
   - OCI-compatible VM-backed containers
   - Multiple hypervisor support
   - **BLOCKER:** 2-4x slower Docker-in-Docker
   - Used by Alibaba, IBM, Baidu
   - 550+ lines

---

## Quick Reference Tables

### Requirements Matrix

| Requirement | Sysbox | Firecracker | Flintlock | gVisor | Kata |
|------------|--------|-------------|-----------|--------|------|
| Docker-in-Docker | ✅ | ⚠️ | ❌ | ⚠️ | ❌ |
| Bind Mounts | ✅ | ❌ | ❌ | ✅ | ⚠️ |
| Dynamic Networking | ✅ | ❌ | ❌ | ✅ | ⚠️ |
| Port Binding | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Snapshots | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |
| Security | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| API Maturity | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Performance | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |
| Ops Complexity | ⚠️ | ❌ | ❌ | ✅ | ⚠️ |

**Legend:** ✅ Good | ⚠️ Issues | ❌ Critical blocker

### Performance Comparison

| Metric | Sysbox | Firecracker | gVisor | Kata |
|--------|--------|-------------|--------|------|
| Boot Time | 2-5s | 125ms ✅ | 2-5s | 125-500ms |
| Memory/Container | 10-50MB | <5MB ✅ | 10-50MB | 15-30MB |
| CPU Overhead | ~1% ✅ | ~5% | ~10% | ~5-10% |
| Docker Build Speed | Baseline ✅ | N/A | Slower | 2-4x slower ❌ |

### Security Comparison

**Isolation Strength** (weakest → strongest):
1. Docker (vanilla runc)
2. **Docker + Sysbox** ← Current
3. gVisor
4. Kata Containers
5. Firecracker

**Verdict:** Sysbox provides sufficient isolation for Sandcastle's use case (developer sandboxes, trusted-but-isolated users)

---

## Key Findings

### Why Docker + Sysbox Wins

1. **Only solution optimized for Docker-in-Docker**
   - Persistent workspaces (`/persisted` volumes)
   - Near-native performance
   - Full Docker API support

2. **Works everywhere Docker works**
   - No nested virtualization required
   - Compatible with cloud VMs
   - Runs inside Docker containers (Rails app)

3. **Production-proven for 2+ years**
   - Stable operation
   - Known operational model
   - Docker corporate backing

4. **Dynamic networking support**
   - Tailscale per-user bridges
   - WeTTY ephemeral sidecars
   - Connect/disconnect at runtime

### Why Alternatives Don't Work

**Firecracker:**
- ❌ No virtio-fs or 9p filesystem sharing
- ❌ Cannot bind-mount `/data/users/{name}/home`
- ❌ No hot-plug networking (breaks Tailscale/WeTTY UX)

**Flintlock:**
- ❌ Firecracker can't run inside Docker (where Rails lives)
- ❌ Would require architectural redesign
- ⚠️ Community-led, inconsistent releases

**gVisor:**
- ❌ Docker-in-Docker requires tmpfs-only overlay
- ❌ All container changes are ephemeral (lost on restart)
- ❌ Breaks persistent workspace model

**Kata Containers:**
- ❌ Docker builds are 2-4x slower
- ❌ Image pulls are 2-3x slower
- ⚠️ Requires nested virtualization
- ⚠️ 40-50% I/O degradation on bind mounts

---

## Recommendations

### Short-Term (Next 6 months)
✅ **Keep Docker + Sysbox**
- No viable alternatives exist
- Migration risk outweighs uncertain benefits
- Current solution works well in production

### Medium-Term (6-18 months)
🔍 **Monitor for improvements:**
- Firecracker: filesystem sharing, hot-plug networking
- Kata: Docker-in-Docker performance optimizations
- gVisor: persistent overlay support

### Long-Term (18+ months)
🔮 **Consider hybrid approach:**
- Standard tier: Docker + Sysbox (default, $10/month)
- High-security tier: Kata/Firecracker (opt-in, $25/month)
- Requires container service abstraction layer (Issue #17 Phase 1)

---

## Research Methodology

### Approach
1. **Parallel research agents** — 5 specialized agents ran concurrently
2. **Sandcastle-specific focus** — Evaluated against actual requirements
3. **Production reality** — Considered operational complexity, not just features
4. **No assumptions** — Deep research from official docs, benchmarks, production use cases

### Evaluation Criteria
- ✅ Docker-in-Docker support (CRITICAL)
- ✅ Persistent bind mounts (CRITICAL)
- ✅ Dynamic networking (HIGH)
- ✅ Port binding and SSH (CRITICAL)
- ✅ Snapshots/restore (HIGH)
- ✅ Security isolation (HIGH)
- ✅ API maturity (HIGH)
- ✅ Performance (MEDIUM)
- ✅ Operational complexity (MEDIUM)
- ✅ Production readiness (HIGH)
- ✅ Deployment flexibility (MEDIUM)

### Sources
- Official documentation for all technologies
- GitHub repositories and issue trackers
- Production deployment case studies
- Performance benchmarks from independent sources
- Security advisories and CVE databases
- Community discussions and expert blogs

---

## How to Use This Research

### For Decision-Making
1. Read [COMPARISON.md](./COMPARISON.md) executive summary
2. Review requirements matrix and decision tree
3. Check individual technology reports for details
4. Use decision matrix to evaluate future alternatives

### For Implementation Planning
- If staying with Sysbox: Document limitations in ops runbook
- If considering alternatives: Review implementation complexity sections
- If building abstraction layer: Use requirements matrix as interface spec

### For Future Re-evaluation
- Monitor technology improvements (listed in recommendations)
- Watch for CVEs affecting Sysbox or user namespaces
- Track Docker's Sysbox maintenance commitment
- Reassess when compliance requirements change

---

## Related Resources

### Internal
- [GitHub Issue #17](https://github.com/thieso2/Sandcastle/issues/17) — Original Firecracker research
- [CLAUDE.md](../CLAUDE.md) — Project architecture overview
- [app/services/sandbox_manager.rb](../app/services/sandbox_manager.rb) — Current Docker implementation

### External
- [Nestybox Sysbox](https://github.com/nestybox/sysbox) — Current runtime
- [AWS Firecracker](https://firecracker-microvm.github.io/) — MicroVM technology
- [Google gVisor](https://gvisor.dev/) — Userspace kernel
- [Kata Containers](https://katacontainers.io/) — VM-backed containers
- [Flintlock](https://github.com/liquidmetal-dev/flintlock) — Firecracker manager

---

## Timeline

- **Research Duration:** ~20 minutes (parallel agents)
- **Documents Created:** 6 reports totaling 2,500+ lines
- **Technologies Evaluated:** 5
- **Recommendation Confidence:** High (all alternatives have fundamental blockers)

---

## Contributors

- Research conducted by: Claude Sonnet 4.5
- Using: 5 parallel specialized research agents
- For: Sandcastle project (thieso2)
- Date: February 13, 2026

---

## Questions?

For questions about this research:
- Review [COMPARISON.md](./COMPARISON.md) for detailed analysis
- Check individual technology reports for specifics
- Refer to [GitHub Issue #17](https://github.com/thieso2/Sandcastle/issues/17) for discussion
- Consult external documentation linked above

**Note:** This research reflects the state of technologies as of February 2026. Re-evaluate periodically as technologies evolve.
