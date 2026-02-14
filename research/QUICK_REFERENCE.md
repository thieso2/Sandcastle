# Quick Reference: Container Isolation Technologies for Sandcastle

**TL;DR:** Keep Docker + Sysbox. All alternatives have critical blockers.

---

## One-Line Summary for Each Technology

| Technology | Summary | Verdict |
|------------|---------|---------|
| **Docker + Sysbox** | Current solution, optimized for Docker-in-Docker | ✅ **KEEP** |
| **Firecracker** | AWS microVMs, no filesystem sharing | ❌ **BLOCKER** |
| **Flintlock** | Firecracker manager, no nested virt | ❌ **BLOCKER** |
| **gVisor** | Google userspace kernel, ephemeral Docker-in-Docker | ❌ **BLOCKER** |
| **Kata Containers** | VM-backed containers, 2-4x slower DinD | ⚠️ **TOO SLOW** |

---

## Critical Blockers

### Firecracker
**❌ No filesystem sharing** — Cannot bind-mount `/data/users/{name}/home` or `/workspace`

### Flintlock
**❌ No nested virtualization** — Firecracker can't run inside Docker containers where Rails lives

### gVisor
**❌ Ephemeral Docker-in-Docker** — All container changes lost on restart (tmpfs-only overlay)

### Kata Containers
**❌ Performance** — Docker builds 2-4x slower, I/O 40-50% degraded

---

## Requirements Matrix (Quick View)

```
Feature                 Sysbox  Fire  Flint  gVisor  Kata
────────────────────────────────────────────────────────
Docker-in-Docker        ✅      ⚠️    ❌     ⚠️      ❌
Persistent Workspaces   ✅      ❌    ❌     ❌      ⚠️
Bind Mounts             ✅      ❌    ❌     ✅      ⚠️
Dynamic Networking      ✅      ❌    ❌     ✅      ⚠️
Simple API              ✅      ⚠️    ⚠️     ✅      ✅
Good Performance        ✅      ✅    ✅     ⚠️      ⚠️
Works in Cloud VMs      ✅      ⚠️    ⚠️     ✅      ⚠️
Low Ops Complexity      ⚠️      ❌    ❌     ✅      ⚠️
```

**✅ = Good** | **⚠️ = Issues** | **❌ = Critical Problem**

---

## Performance Comparison

```
Metric              Sysbox    Firecracker  gVisor    Kata
─────────────────────────────────────────────────────────
Boot Time           2-5s      125ms ✅     2-5s      125-500ms
CPU Overhead        ~1% ✅    ~5%          ~10%      ~5-10%
Docker Build        1x ✅     N/A          Slower    2-4x slower ❌
I/O Performance     ~95% ✅   N/A          ~40-70%   ~50-60%
```

---

## Security Comparison

**Isolation Strength** (weakest → strongest):

```
1. Docker (vanilla runc)
2. Docker + Sysbox ← Current solution
3. gVisor
4. Kata Containers
5. Firecracker
```

**For Sandcastle's use case (developer sandboxes):**
- Sysbox provides **sufficient isolation**
- Kernel-level boundaries + user namespaces
- Acceptable for trusted-but-isolated users

**When you'd need stronger isolation:**
- Running truly untrusted code (malware analysis)
- Compliance requires hardware isolation
- Multi-tenant SaaS with strict boundaries

---

## Decision Tree

```
Does it need persistent workspaces?
├─ YES (Sandcastle requirement)
│  └─ Does it need good Docker-in-Docker performance?
│     ├─ YES (Core feature)
│     │  └─ Does it need dynamic networking?
│     │     ├─ YES (Tailscale, WeTTY)
│     │     │  └─ ✅ Docker + Sysbox ONLY option
│     │     └─ NO
│     │        └─ ⚠️ Kata (if 2-4x slower acceptable)
│     └─ NO
│        └─ ❌ Not Sandcastle's use case
└─ NO (ephemeral)
   └─ ⚠️ Firecracker or gVisor
```

**Result:** Docker + Sysbox is the only viable option.

---

## Recommendations

### Now
✅ **Keep Docker + Sysbox**

### Next 6 Months
🔍 **Monitor for:**
- Sysbox project health
- CVEs affecting user namespaces
- Docker maintenance commitment

### Next 6-18 Months
🔍 **Watch for improvements:**
- Firecracker: filesystem sharing support
- Kata: Docker-in-Docker optimizations
- gVisor: persistent overlay support

### Next 18+ Months
🔮 **Consider hybrid:**
- Standard tier: Sysbox (default)
- High-security tier: Kata/Firecracker (premium)

---

## When to Re-evaluate

**Only if:**
- ❗ Major CVE affects Sysbox
- ❗ Docker stops maintaining Sysbox
- ❗ Compliance requires hardware isolation
- ❗ Better Docker-in-Docker alternative emerges

**Don't re-evaluate just because:**
- ⛔ A blog post says "VMs are better"
- ⛔ New container tech gets released
- ⛔ Competitors use different tech

---

## Common Questions

### Q: "But VMs have stronger isolation!"
**A:** True, but Sysbox's isolation is sufficient for Sandcastle's threat model (developer sandboxes). The trade-offs (performance, complexity, features) aren't worth it.

### Q: "What about Firecracker? AWS uses it!"
**A:** AWS Lambda is ephemeral code execution with no persistent storage. Sandcastle needs persistent workspaces (`/workspace`), which Firecracker doesn't support.

### Q: "Can't we just use Kata for stronger security?"
**A:** Kata makes Docker builds 2-4x slower. This is Sandcastle's core feature. Users would have a terrible experience.

### Q: "Should we build an abstraction layer?"
**A:** Not yet. Wait until there's a viable alternative before investing 3-4 weeks in abstraction work.

### Q: "What if a customer demands VM isolation?"
**A:** Consider a hybrid approach: Standard tier (Sysbox) + Premium tier (Kata/Firecracker). But validate demand first.

---

## Full Research

For detailed analysis, see:
- **[COMPARISON.md](./COMPARISON.md)** — Main comparison (20+ pages)
- **[README.md](./README.md)** — Research overview
- **Individual reports:** `docker-sysbox.md`, `firecracker.md`, `flintlock.md`, `gvisor.md`, `kata-containers.md`

---

**Bottom Line:** Docker + Sysbox is the right choice. Don't overthink it.
