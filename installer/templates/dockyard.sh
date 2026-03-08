#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Env loading ──────────────────────────────────────────────

LOADED_ENV_FILE=""

# Returns 0 on success, 1 if no config file exists.
# Exits immediately if DOCKYARD_ENV is set but the file is missing.
try_load_env() {
    local script_env="${SCRIPT_DIR}/../etc/dockyard.env"
    local root_env="${DOCKYARD_ROOT:-/dockyard}/etc/dockyard.env"

    if [ -n "${DOCKYARD_ENV:-}" ]; then
        if [ ! -f "$DOCKYARD_ENV" ]; then
            echo "Error: DOCKYARD_ENV file not found: ${DOCKYARD_ENV}" >&2
            exit 1
        fi
        LOADED_ENV_FILE="$(cd "$(dirname "$DOCKYARD_ENV")" && pwd)/$(basename "$DOCKYARD_ENV")"
    elif [ -f "./dockyard.env" ]; then
        LOADED_ENV_FILE="$(pwd)/dockyard.env"
    elif [ -f "$script_env" ]; then
        LOADED_ENV_FILE="$(cd "$(dirname "$script_env")" && pwd)/$(basename "$script_env")"
    elif [ -f "$root_env" ]; then
        LOADED_ENV_FILE="$root_env"
    else
        return 1
    fi

    echo "Loading ${LOADED_ENV_FILE}..."
    set -a; source "$LOADED_ENV_FILE"; set +a
}

load_env() {
    if ! try_load_env; then
        echo "Error: No config found." >&2
        echo "Run './dockyard.sh gen-env' to generate one, or set DOCKYARD_ENV." >&2
        exit 1
    fi
}

derive_vars() {
    DOCKYARD_ROOT="${DOCKYARD_ROOT:-/dockyard}"
    DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-172.30.0.1/24}"
    DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-172.30.0.0/24}"
    DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-172.31.0.0/16}"
    DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

    BIN_DIR="${DOCKYARD_ROOT}/bin"
    ETC_DIR="${DOCKYARD_ROOT}/etc"
    LOG_DIR="${DOCKYARD_ROOT}/log"
    RUN_DIR="${DOCKYARD_ROOT}/run"
    BRIDGE="${DOCKYARD_DOCKER_PREFIX}docker0"
    SERVICE_NAME="${DOCKYARD_DOCKER_PREFIX}docker"
    DOCKER_SOCKET="${DOCKYARD_ROOT}/run/docker.sock"
    CONTAINERD_SOCKET="${DOCKYARD_ROOT}/run/containerd/containerd.sock"
    DOCKER_DATA="${DOCKYARD_ROOT}/lib/docker"
    DOCKER_CONFIG_DIR="${DOCKYARD_ROOT}/lib/docker-config"

    # Per-instance system user and group (socket ownership + access control)
    INSTANCE_USER="${DOCKYARD_DOCKER_PREFIX}docker"
    INSTANCE_GROUP="${DOCKYARD_DOCKER_PREFIX}docker"

    # Per-instance sysbox daemons (separate sysbox-mgr + sysbox-fs per installation)
    SYSBOX_RUN_DIR="${DOCKYARD_ROOT}/run/sysbox"
    SYSBOX_DATA_DIR="${DOCKYARD_ROOT}/lib/sysbox"
}

# ── Helpers ──────────────────────────────────────────────────

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: must run as root (use sudo)" >&2
        exit 1
    fi
}

stop_daemon() {
    local name="$1"
    local pidfile="$2"
    local timeout="${3:-10}"

    if [ ! -f "$pidfile" ]; then
        echo "${name}: no pid file"
        return 0
    fi

    local pid
    pid=$(cat "$pidfile")

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "${name}: not running (stale pid ${pid})"
        rm -f "$pidfile"
        return 0
    fi

    echo "Stopping ${name} (pid ${pid})..."
    kill "$pid"

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "  ${name} did not stop in ${timeout}s — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
            break
        fi
    done

    rm -f "$pidfile"
    echo "  ${name} stopped"
}

cleanup_pool_bridges() {
    # Remove leftover kernel bridge interfaces (br-*) whose IP falls within
    # DOCKYARD_POOL_BASE. When dockerd exits, it does not clean up user-defined
    # network bridges. Left behind, they cause "overlaps with existing routes"
    # errors on the next install because the pool CIDR is still in the routing table.
    local pool_base="${DOCKYARD_POOL_BASE:-}"
    [ -n "$pool_base" ] || return 0

    # Extract the first two octets of the pool base (e.g. "10.89" from "10.89.0.0/16")
    local pool_prefix
    pool_prefix=$(echo "$pool_base" | grep -oP '^\d+\.\d+')

    local removed=0
    while IFS= read -r iface; do
        [[ "$iface" == br-* ]] || continue
        local iface_ip
        iface_ip=$(ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
        if [[ -n "$iface_ip" && "$iface_ip" == ${pool_prefix}.* ]]; then
            echo "Removing leftover pool bridge: ${iface} (${iface_ip})"
            ip link set "$iface" down 2>/dev/null || true
            ip link delete "$iface" 2>/dev/null || true
            removed=$((removed + 1))
        fi
    done < <(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:@]+')

    [ "$removed" -gt 0 ] || true
}

wait_for_file() {
    local file="$1"
    local label="$2"
    local timeout="${3:-30}"
    local i=0
    while [ ! -S "$file" ]; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "Error: $label did not become ready within ${timeout}s" >&2
            return 1
        fi
    done
}

# ── Collision checks ─────────────────────────────────────────

check_prefix_conflict() {
    local prefix="${1:-$DOCKYARD_DOCKER_PREFIX}"
    local bridge="${prefix}docker0"
    local docker_service="${prefix}docker.service"
    local sysbox_service="${prefix}sysbox.service"

    if ip link show "$bridge" &>/dev/null; then
        echo "Error: Bridge ${bridge} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$docker_service" &>/dev/null 2>&1 && systemctl cat "$docker_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${docker_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$sysbox_service" &>/dev/null 2>&1 && systemctl cat "$sysbox_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${sysbox_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_root_conflict() {
    local root="${1:-$DOCKYARD_ROOT}"
    if [ -d "${root}/bin" ]; then
        echo "Error: ${root}/bin/ already exists — dockyard is already installed at this root." >&2
        echo "Use: DOCKYARD_ROOT=/other/path ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_private_cidr() {
    local cidr="$1"
    local label="$2"
    local ip="${cidr%/*}"
    local o1 o2
    IFS='.' read -r o1 o2 _ <<< "$ip"

    # 10.0.0.0/8
    if [ "$o1" -eq 10 ]; then return 0; fi
    # 172.16.0.0/12
    if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi
    # 192.168.0.0/16
    if [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then return 0; fi

    echo "Error: ${label} ${cidr} is not in an RFC 1918 private range." >&2
    echo "  Valid ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16" >&2
    return 1
}

check_subnet_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"

    local fixed_net="${fixed_cidr%/*}"
    if ip route | grep -qF "${fixed_net}/"; then
        echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} conflicts with an existing route:" >&2
        echo "  $(ip route | grep -F "${fixed_net}/")" >&2
        return 1
    fi

    local pool_net="${pool_base%/*}"
    local pool_two_octets="${pool_net%.*.*}"
    if ip route | grep -qE "^${pool_two_octets}\."; then
        echo "Error: DOCKYARD_POOL_BASE ${pool_base} overlaps with existing routes:" >&2
        echo "  $(ip route | grep -E "^${pool_two_octets}\.")" >&2
        return 1
    fi
    return 0
}

# Cross-check proposed CIDRs against sibling dockyard env files in the given
# directory.  Prevents gen-env for instance B from picking a pool range that
# shares a /16 with instance A's bridge CIDR (and vice versa), which would
# cause a conflict when concurrent creates bring A's bridge up before B's
# check_subnet_conflict runs.
check_sibling_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"
    local env_dir="$3"

    [ -d "$env_dir" ] || return 0

    local our_bridge_two our_pool_two
    our_bridge_two="${fixed_cidr%.*.*}"     # e.g. "172.21" from 172.21.116.0/24
    our_pool_two="${pool_base%/*}"
    our_pool_two="${our_pool_two%.*.*}"     # e.g. "172.21" from 172.21.0.0/16

    for sibling in "${env_dir}"/*.env; do
        [ -f "$sibling" ] || continue
        local sib_fixed sib_pool
        sib_fixed=$(grep '^DOCKYARD_FIXED_CIDR=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        sib_pool=$(grep '^DOCKYARD_POOL_BASE=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        [ -n "${sib_fixed}${sib_pool}" ] || continue

        if [ -n "$sib_fixed" ]; then
            local sib_two="${sib_fixed%.*.*}"
            # Our pool must not share a /16 with a sibling's bridge
            if [ "$our_pool_two" = "$sib_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling bridge ${sib_fixed} (from ${sibling})" >&2
                return 1
            fi
        fi
        if [ -n "$sib_pool" ]; then
            local sib_pool_two="${sib_pool%/*}"
            sib_pool_two="${sib_pool_two%.*.*}"
            # Our bridge must not share a /16 with a sibling's pool
            if [ "$our_bridge_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
            # Our pool must not share a /16 with a sibling's pool
            if [ "$our_pool_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
        fi
    done
    return 0
}

# ── Commands ─────────────────────────────────────────────────

cmd_gen_env() {
    local NOCHECK=false
    for arg in "$@"; do
        case "$arg" in
            --nocheck)  NOCHECK=true ;;
            -h|--help)  gen_env_usage ;;
            --*)        echo "Unknown option: $arg" >&2; gen_env_usage ;;
        esac
    done

    # Determine output file
    local out_file="${DOCKYARD_ENV:-./dockyard.env}"
    if [ -f "$out_file" ]; then
        echo "Error: ${out_file} already exists. Remove it first or set DOCKYARD_ENV to a different path." >&2
        exit 1
    fi

    # Apply env var overrides or defaults
    local root="${DOCKYARD_ROOT:-/dockyard}"
    local prefix="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    local pool_size="${DOCKYARD_POOL_SIZE:-24}"

    # Generate random networks if not provided via env
    local bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-}"
    local fixed_cidr="${DOCKYARD_FIXED_CIDR:-}"
    local pool_base="${DOCKYARD_POOL_BASE:-}"

    if [ -z "$bridge_cidr" ] || [ -z "$fixed_cidr" ] || [ -z "$pool_base" ]; then
        local attempts=0
        local max_attempts=10

        while [ $attempts -lt $max_attempts ]; do
            attempts=$((attempts + 1))

            # Random /24 from 172.16.0.0/12 for bridge
            local b2=$(( RANDOM % 16 + 16 ))   # 16-31
            local b3=$(( RANDOM % 256 ))        # 0-255
            bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-172.${b2}.${b3}.1/24}"
            fixed_cidr="${DOCKYARD_FIXED_CIDR:-172.${b2}.${b3}.0/24}"

            # Random /16 from 172.16.0.0/12 for pool (different second octet)
            local p2=$(( RANDOM % 16 + 16 ))    # 16-31
            while [ "$p2" -eq "$b2" ]; do
                p2=$(( RANDOM % 16 + 16 ))
            done
            pool_base="${DOCKYARD_POOL_BASE:-172.${p2}.0.0/16}"

            if [ "$NOCHECK" = true ]; then
                break
            fi

            local env_dir
            env_dir="$(cd "$(dirname "${out_file}")" 2>/dev/null && pwd)" || env_dir=""
            if check_subnet_conflict "$fixed_cidr" "$pool_base" 2>/dev/null && \
               check_sibling_conflict "$fixed_cidr" "$pool_base" "$env_dir" 2>/dev/null; then
                break
            fi

            # Reset for next attempt (only re-randomize what wasn't user-provided)
            [ -n "${DOCKYARD_BRIDGE_CIDR:-}" ] || bridge_cidr=""
            [ -n "${DOCKYARD_FIXED_CIDR:-}" ] || fixed_cidr=""
            [ -n "${DOCKYARD_POOL_BASE:-}" ] || pool_base=""

            if [ $attempts -eq $max_attempts ]; then
                echo "Error: Could not find non-conflicting subnets after ${max_attempts} attempts." >&2
                echo "Provide explicit values via DOCKYARD_BRIDGE_CIDR, DOCKYARD_FIXED_CIDR, DOCKYARD_POOL_BASE." >&2
                exit 1
            fi
        done
    else
        # All three provided explicitly — validate unless --nocheck
        if [ "$NOCHECK" = false ]; then
            check_subnet_conflict "$fixed_cidr" "$pool_base" || exit 1
        fi
    fi

    # Validate all CIDRs are in RFC 1918 private ranges
    check_private_cidr "$bridge_cidr" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$fixed_cidr"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$pool_base"   "DOCKYARD_POOL_BASE"   || exit 1

    # Conflict checks (unless --nocheck)
    if [ "$NOCHECK" = false ]; then
        check_prefix_conflict "$prefix" || exit 1
        check_root_conflict "$root" || exit 1
    fi

    # Write config file
    cat > "$out_file" <<EOF
# Dockyard configuration
# Generated by: dockyard.sh gen-env

DOCKYARD_ROOT=${root}
DOCKYARD_DOCKER_PREFIX=${prefix}
DOCKYARD_BRIDGE_CIDR=${bridge_cidr}
DOCKYARD_FIXED_CIDR=${fixed_cidr}
DOCKYARD_POOL_BASE=${pool_base}
DOCKYARD_POOL_SIZE=${pool_size}
EOF

    echo "Generated ${out_file}:"
    echo ""
    cat "$out_file"
}

cmd_create() {
    local INSTALL_SYSTEMD=true
    local START_DAEMON=true
    for arg in "$@"; do
        case "$arg" in
            --no-systemd) INSTALL_SYSTEMD=false ;;
            --no-start)   START_DAEMON=false ;;
            -h|--help)    create_usage ;;
            --*)          echo "Unknown option: $arg" >&2; create_usage ;;
        esac
    done

    require_root

    # Preflight: check for required system tools
    local missing=()
    for tool in curl iptables rsync; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: missing required tools: ${missing[*]}" >&2
        echo "Install them first, e.g.: apt-get install -y ${missing[*]}" >&2
        exit 1
    fi

    echo "Installing dockyard docker..."
    echo "  DOCKYARD_ROOT:          ${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX: ${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR:   ${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR:    ${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE:     ${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE:     ${DOCKYARD_POOL_SIZE}"
    echo ""
    echo "  bridge:      ${BRIDGE}"
    echo "  service:     ${SERVICE_NAME}.service"
    echo "  root:        ${DOCKYARD_ROOT}"
    echo "  data:        ${DOCKER_DATA}"
    echo "  socket:      ${DOCKER_SOCKET}"
    echo "  user:        ${INSTANCE_USER}"
    echo "  group:       ${INSTANCE_GROUP}"
    echo ""

    # --- Check for existing installation ---
    check_private_cidr "$DOCKYARD_BRIDGE_CIDR" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$DOCKYARD_FIXED_CIDR"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$DOCKYARD_POOL_BASE"   "DOCKYARD_POOL_BASE"   || exit 1
    check_root_conflict "$DOCKYARD_ROOT" || exit 1
    check_prefix_conflict "$DOCKYARD_DOCKER_PREFIX" || exit 1
    check_subnet_conflict "$DOCKYARD_FIXED_CIDR" "$DOCKYARD_POOL_BASE" || exit 1

    # --- 1. Download and extract binaries ---
    local CACHE_DIR="${SCRIPT_DIR}/.tmp"

    # Version compatibility notes — do not upgrade these without reading:
    #
    # DOCKER_VERSION: static binary from download.docker.com/linux/static/stable.
    #   Uses sysbox-runc as default runtime → the bundled runc 1.3.3 is never
    #   called for sandbox containers, so this version does NOT trigger the
    #   sysbox procfs incompatibility (nestybox/sysbox#973).
    #
    # SYSBOX_VERSION: 0.6.7.10-tc is a patched fork (github.com/thieso2/sysbox)
    #   that adds --run-dir to sysbox-mgr, sysbox-fs, and sysbox-runc, allowing
    #   N independent sysbox instances per host (each with its own socket dir).
    #   SetRunDir() calls os.Setenv("SYSBOX_RUN_DIR", dir) and os.Args is scanned
    #   directly in init() — bypasses urfave/cli v1 so --run-dir via runtimeArgs
    #   works correctly for all three sockets including the seccomp tracer.
    #   No wrapper script needed.
    #   Fixed: https://github.com/thieso2/sysbox/issues/5
    #   Distributed as a static tarball (no .deb, no dpkg dependency).
    #   0.6.7.10-tc is the first release with an aarch64 static tarball.
    #   NOTE: 0.7.0.1-tc has a netns regression — do not upgrade until fixed
    #   (see https://github.com/thieso2/sysbox/issues/9)

    # --- Detect CPU architecture ---
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
    echo "  arch:        ${ARCH}"
    echo ""

    local DOCKER_VERSION="29.2.1"
    local DOCKER_ROOTLESS_VERSION="29.2.1"
    local SYSBOX_VERSION="0.6.7.10-tc"
    local SYSBOX_TARBALL="sysbox-static-${ARCH}.tar.gz"
    local COMPOSE_VERSION="2.32.4"

    # SHA256 checksums — must match exactly; cache hits are also verified
    # (protects against cache poisoning and mirror tampering)
    local DOCKER_SHA256 DOCKER_ROOTLESS_SHA256 SYSBOX_SHA256 COMPOSE_SHA256
    case "$ARCH" in
        x86_64)
            DOCKER_SHA256="995b1d0b51e96d551a3b49c552c0170bc6ce9f8b9e0866b8c15bbc67d1cf93a3"
            DOCKER_ROOTLESS_SHA256="8c7b7783d8b391ca3183d9b5c7dea1794f6de69cfaa13c45f61fcd17d2b9c3ef"
            SYSBOX_SHA256="9107dca08cc69c5871a0be7981dec3a3e8e5aa6e0924b7a6ca36df324357274b"
            COMPOSE_SHA256="ed1917fb54db184192ea9d0717bcd59e3662ea79db48bff36d3475516c480a6b"
            ;;
        aarch64)
            DOCKER_SHA256="236c5064473295320d4bf732fbbfc5b11b6b2dc446e8bc7ebb9222015fb36857"
            DOCKER_ROOTLESS_SHA256="15895df8b46ff33179d357e61b600b5b51242f9b9587c0f66695689e62f57894"
            SYSBOX_SHA256="6a543f863cf77cbec285f9eebbbe5d5e5c0f3fd3836347909b4ef1e4b3fc03ef"
            COMPOSE_SHA256="0c4591cf3b1ed039adcd803dbbeddf757375fc08c11245b0154135f838495a2f"
            ;;
    esac

    local DOCKER_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz"
    local DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
    local SYSBOX_URL="https://github.com/thieso2/sysbox/releases/download/v${SYSBOX_VERSION}/${SYSBOX_TARBALL}"
    local COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "$ETC_DIR" "$BIN_DIR"
    mkdir -p "$DOCKER_DATA" "$DOCKER_CONFIG_DIR"
    mkdir -p "${RUN_DIR}/containerd"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$SYSBOX_RUN_DIR"
    mkdir -p "$SYSBOX_DATA_DIR"

    # Create system user and group for this instance.
    # dockerd runs as root but creates the socket owned by this group (--group flag),
    # so operators simply join the group to get socket access without sudo.
    if ! getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupadd --system "${INSTANCE_GROUP}"
        echo "  Created group ${INSTANCE_GROUP}"
    else
        echo "  Group ${INSTANCE_GROUP} already exists"
    fi
    if ! getent passwd "${INSTANCE_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false \
            --gid "${INSTANCE_GROUP}" "${INSTANCE_USER}"
        echo "  Created user ${INSTANCE_USER}"
    else
        echo "  User ${INSTANCE_USER} already exists"
    fi

    # Allow sysbox-fs FUSE mounts at this instance's sysbox mountpoint.
    # The default fusermount3 AppArmor profile (tightened in Ubuntu 25.10+)
    # only permits FUSE mounts under $HOME, /mnt, /tmp, etc.  Without this
    # override every sysbox container fails with a context-deadline-exceeded
    # RPC error from sysbox-fs.
    # Each instance appends a tagged block; destroy removes it.
    if [ -d /etc/apparmor.d ]; then
        mkdir -p /etc/apparmor.d/local
        local apparmor_file="/etc/apparmor.d/local/fusermount3"
        local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
        local apparmor_end="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end"
        {
            flock -x 9
            if ! grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
                {
                    echo "$apparmor_begin"
                    # Ubuntu 25.10+ comments out dac_override in the base fusermount3
                    # profile (LP: #2122161). sysbox-fs needs it for FUSE mounts.
                    echo "capability dac_override,"
                    echo "mount fstype=fuse options=(nosuid,nodev) options in (ro,rw) -> ${SYSBOX_DATA_DIR}/**/,"
                    echo "umount ${SYSBOX_DATA_DIR}/**/,"
                    echo "$apparmor_end"
                } >> "$apparmor_file"
            fi
        } 9>"${apparmor_file}.lock"
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3
            echo "  AppArmor fusermount3 profile updated for ${SYSBOX_DATA_DIR}"
        fi
    fi

    verify_checksum() {
        local file="$1" expected="$2" name="$3"
        local actual
        actual=$(sha256sum "$file" | awk '{print $1}')
        if [ "$actual" != "$expected" ]; then
            echo "Error: SHA256 mismatch for $name" >&2
            echo "  expected: $expected" >&2
            echo "  got:      $actual" >&2
            rm -f "$file"
            exit 1
        fi
    }

    download() {
        local url="$1"
        local expected_sha256="$2"
        local dest="${CACHE_DIR}/$(basename "$url")"
        if [ -f "$dest" ]; then
            echo "  cached: $(basename "$dest")"
        else
            echo "  downloading: $(basename "$url")"
            curl -fsSL -o "${dest}.tmp.$$" "$url" && mv "${dest}.tmp.$$" "$dest"
        fi
        verify_checksum "$dest" "$expected_sha256" "$(basename "$url")"
    }

    echo "Downloading artifacts..."
    download "$DOCKER_URL"          "$DOCKER_SHA256"
    download "$DOCKER_ROOTLESS_URL" "$DOCKER_ROOTLESS_SHA256"
    download "$SYSBOX_URL"          "$SYSBOX_SHA256"
    download "$COMPOSE_URL"         "$COMPOSE_SHA256"

    # Use per-PID staging dirs for extraction so concurrent creates don't race
    # on a shared extraction directory (all instances share the same CACHE_DIR).
    local STAGING="${CACHE_DIR}/staging-$$"
    mkdir -p "$STAGING"
    trap 'rm -rf "$STAGING"' RETURN INT TERM

    echo "Extracting Docker binaries..."
    tar -xzf "${CACHE_DIR}/docker-${DOCKER_VERSION}.tgz" -C "$STAGING"
    cp -f "${STAGING}/docker/"* "$BIN_DIR/"

    echo "Extracting Docker rootless extras..."
    tar -xzf "${CACHE_DIR}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz" -C "$STAGING"
    cp -f "${STAGING}/docker-rootless-extras/"* "$BIN_DIR/"

    echo "Extracting sysbox static binaries..."
    local SYSBOX_EXTRACT="${STAGING}/sysbox-static-${SYSBOX_VERSION}"
    mkdir -p "$SYSBOX_EXTRACT"
    tar -xzf "${CACHE_DIR}/${SYSBOX_TARBALL}" -C "$SYSBOX_EXTRACT"
    # All three sysbox binaries go directly to BIN_DIR.
    # sysbox-runc 0.6.7.9-tc parses --run-dir directly from os.Args in init(),
    # bypassing urfave/cli v1 entirely. runtimeArgs in daemon.json now works.
    # See: https://github.com/thieso2/sysbox/issues/5
    for bin in sysbox-runc sysbox-mgr sysbox-fs; do
        local src
        src=$(find "$SYSBOX_EXTRACT" -name "$bin" -type f | head -1)
        if [ -z "$src" ]; then
            echo "Error: $bin not found in ${SYSBOX_TARBALL}" >&2
            exit 1
        fi
        cp -f "$src" "$BIN_DIR/$bin"
        chmod +x "$BIN_DIR/$bin"
    done

    # Install Docker Compose v2 plugin
    echo "Installing Docker Compose plugin..."
    mkdir -p "${DOCKER_CONFIG_DIR}/cli-plugins"
    cp -f "${CACHE_DIR}/docker-compose-linux-${ARCH}" "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose"
    chmod +x "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose"

    chmod +x "$BIN_DIR"/*

    # Rename docker CLI binary, replace with DOCKER_HOST wrapper
    mv -f "${BIN_DIR}/docker" "${BIN_DIR}/docker-cli"
    cat > "${BIN_DIR}/docker" <<DOCKEREOF
#!/bin/bash
export DOCKER_HOST="unix://${DOCKER_SOCKET}"
export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"
exec "\$(dirname "\$0")/docker-cli" "\$@"
DOCKEREOF
    chmod +x "${BIN_DIR}/docker"

    echo "Installed binaries to ${BIN_DIR}/"

    # Write daemon.json (embedded — no external file dependency)
    # sysbox-runc 0.6.7.9-tc parses --run-dir from os.Args in init(), so
    # runtimeArgs works correctly. No wrapper script needed.
    cat > "${ETC_DIR}/daemon.json" <<DAEMONJSONEOF
{
  "default-runtime": "sysbox-runc",
  "runtimes": {
    "sysbox-runc": {
      "path": "${BIN_DIR}/sysbox-runc",
      "runtimeArgs": ["--run-dir", "${SYSBOX_RUN_DIR}"]
    }
  },
  "storage-driver": "overlay2",
  "userland-proxy-path": "${BIN_DIR}/docker-proxy",
  "features": {
    "buildkit": true
  }
}
DAEMONJSONEOF
    echo "Installed config to ${ETC_DIR}/daemon.json"

    # Copy config file and dockyard.sh into instance.
    # Installing as dockyard.sh means the script's own ../etc/dockyard.env
    # auto-discovery works: ${BIN_DIR}/dockyard.sh finds ${ETC_DIR}/dockyard.env
    # without needing DOCKYARD_ENV to be set.
    local _dest="${ETC_DIR}/dockyard.env"
    [ "$(realpath "$LOADED_ENV_FILE")" = "$(realpath "$_dest" 2>/dev/null)" ] \
        || cp "$LOADED_ENV_FILE" "$_dest"
    cp "${SCRIPT_DIR}/dockyard.sh" "${BIN_DIR}/dockyard.sh"
    chmod +x "${BIN_DIR}/dockyard.sh"
    ln -sf dockyard.sh "${BIN_DIR}/dockyardctl"
    echo "Installed env to ${ETC_DIR}/dockyard.env"
    echo "Installed dockyard.sh to ${BIN_DIR}/dockyard.sh"

    # Set ownership of the instance root so every file is attributed to the
    # instance user/group. dockerd still runs as root, so it can write freely;
    # the ownership is for identification and directory-level access control.
    chown -R "${INSTANCE_USER}:${INSTANCE_GROUP}" "${DOCKYARD_ROOT}"
    echo "Set ownership of ${DOCKYARD_ROOT}/ to ${INSTANCE_USER}:${INSTANCE_GROUP}"

    # --- 2. Install systemd service ---
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo ""
        cmd_enable
    fi

    # --- 3. Start daemon ---
    if [ "$START_DAEMON" = true ]; then
        echo ""
        if [ "$INSTALL_SYSTEMD" = true ]; then
            echo "Starting via systemd..."
            systemctl start "${SERVICE_NAME}.service"
            echo "  ${SERVICE_NAME}.service started"
        else
            echo "Starting directly..."
            cmd_start
        fi
    fi

    echo ""
    echo "=== Installation complete ==="
    echo ""
    echo "To use:"
    echo "  ${BIN_DIR}/docker run -ti alpine ash"
    echo ""
    echo "Manage this instance:"
    echo "  ${BIN_DIR}/dockyard.sh status"
    echo "  sudo ${BIN_DIR}/dockyard.sh verify"
    echo "  sudo ${BIN_DIR}/dockyard.sh destroy"
}

cmd_enable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "Error: ${SERVICE_FILE} already exists." >&2
        exit 1
    fi

    echo "Installing ${SERVICE_NAME}.service (with per-instance sysbox)..."

    # Write the stack script (bakes all paths in at install time; no env file at runtime)
    cat > "${BIN_DIR}/dockyard-stack" <<STACKEOF
#!/bin/bash
set -euo pipefail

MGR_PID=""
FS_PID=""
CTR_PID=""
DOCKERD_PID=""

wait_for_socket() {
    local sock="\$1" pid="\$2" name="\$3" i=0
    while [ ! -S "\$sock" ]; do
        sleep 1
        i=\$((i+1))
        if ! kill -0 "\$pid" 2>/dev/null; then
            echo "dockyard-stack: \$name exited unexpectedly" >&2
            return 1
        fi
        if [ "\$i" -ge 60 ]; then
            echo "dockyard-stack: \$name did not start within 60s" >&2
            return 1
        fi
    done
}

cleanup() {
    local code=\${1:-0}
    for pid in "\$DOCKERD_PID" "\$CTR_PID" "\$FS_PID" "\$MGR_PID"; do
        [ -z "\$pid" ] && continue
        kill "\$pid" 2>/dev/null || true
        wait "\$pid" 2>/dev/null || true
    done
    exit "\$code"
}

trap 'cleanup 0' TERM INT

# --- Start sysbox-mgr ---
${BIN_DIR}/sysbox-mgr --run-dir ${SYSBOX_RUN_DIR} --data-root ${SYSBOX_DATA_DIR} \
    >>${LOG_DIR}/sysbox-mgr.log 2>&1 &
MGR_PID=\$!
echo "\$MGR_PID" > ${SYSBOX_RUN_DIR}/sysbox-mgr.pid
wait_for_socket ${SYSBOX_RUN_DIR}/sysmgr.sock "\$MGR_PID" sysbox-mgr || cleanup 1

# --- Start sysbox-fs ---
${BIN_DIR}/sysbox-fs --run-dir ${SYSBOX_RUN_DIR} --mountpoint ${SYSBOX_DATA_DIR} \
    >>${LOG_DIR}/sysbox-fs.log 2>&1 &
FS_PID=\$!
echo "\$FS_PID" > ${SYSBOX_RUN_DIR}/sysbox-fs.pid
wait_for_socket ${SYSBOX_RUN_DIR}/sysfs.sock "\$FS_PID" sysbox-fs || cleanup 1

# --- Start containerd ---
${BIN_DIR}/containerd \
    --root ${DOCKER_DATA}/containerd \
    --state ${RUN_DIR}/containerd \
    --address ${CONTAINERD_SOCKET} \
    >>${LOG_DIR}/containerd.log 2>&1 &
CTR_PID=\$!
echo "\$CTR_PID" > ${RUN_DIR}/containerd.pid
wait_for_socket ${CONTAINERD_SOCKET} "\$CTR_PID" containerd || cleanup 1

# --- Start dockerd ---
${BIN_DIR}/dockerd \
    --config-file ${ETC_DIR}/daemon.json \
    --containerd ${CONTAINERD_SOCKET} \
    --data-root ${DOCKER_DATA} \
    --exec-root ${RUN_DIR} \
    --pidfile ${RUN_DIR}/dockerd.pid \
    --bridge ${BRIDGE} \
    --fixed-cidr ${DOCKYARD_FIXED_CIDR} \
    --default-address-pool base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE} \
    --host unix://${DOCKER_SOCKET} \
    --iptables=false \
    --group ${INSTANCE_GROUP} \
    >>${LOG_DIR}/dockerd.log 2>&1 &
DOCKERD_PID=\$!
wait_for_socket ${DOCKER_SOCKET} "\$DOCKERD_PID" dockerd || cleanup 1

# Signal systemd that all daemon sockets are up.
# || true: sd_notify returns non-zero when not running under systemd; don't abort.
systemd-notify --ready 2>/dev/null || true

# Monitor: if any daemon dies, trigger a restart
while true; do
    sleep 2 &
    wait \$! 2>/dev/null || true
    for check in "sysbox-mgr:\$MGR_PID" "sysbox-fs:\$FS_PID" "containerd:\$CTR_PID" "dockerd:\$DOCKERD_PID"; do
        _name="\${check%%:*}"
        _pid="\${check##*:}"
        if [ -n "\$_pid" ] && ! kill -0 "\$_pid" 2>/dev/null; then
            echo "dockyard-stack: \$_name (pid \$_pid) died unexpectedly" >&2
            cleanup 1
        fi
    done
done
STACKEOF
    chmod 755 "${BIN_DIR}/dockyard-stack"
    echo "  installed ${BIN_DIR}/dockyard-stack"

    cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=Dockyard Docker (${SERVICE_NAME})
After=network-online.target nss-lookup.target firewalld.service time-set.target
Before=docker.service
Wants=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=notify
NotifyAccess=all
Environment=PATH=${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Create runtime and sysbox directories
ExecStartPre=/bin/mkdir -p ${LOG_DIR} ${RUN_DIR}/containerd ${SYSBOX_RUN_DIR} ${DOCKER_DATA}/containerd ${SYSBOX_DATA_DIR}

# Clean stale sockets (including sysbox — stale socket file fools the wait loop)
ExecStartPre=-/bin/rm -f ${CONTAINERD_SOCKET} ${DOCKER_SOCKET}
ExecStartPre=-/bin/rm -f ${SYSBOX_RUN_DIR}/sysmgr.sock ${SYSBOX_RUN_DIR}/sysfs.sock ${SYSBOX_RUN_DIR}/sysfs-seccomp.sock

# Enable IP forwarding
ExecStartPre=/bin/bash -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null'

# Create bridge
ExecStartPre=/bin/bash -c 'if ! ip link show ${BRIDGE} &>/dev/null; then ip link add ${BRIDGE} type bridge && ip addr add ${DOCKYARD_BRIDGE_CIDR} dev ${BRIDGE} && ip link set ${BRIDGE} up; fi'

# Add iptables rules for container networking (bridge) — idempotent: -C check before -I
ExecStartPre=/bin/bash -c 'iptables -C FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT; iptables -C FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT; iptables -C FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -C POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE'

# Add iptables rules for user-defined networks (from default-address-pool) — idempotent
ExecStartPre=/bin/bash -c 'iptables -C FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT; iptables -C FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT; iptables -t nat -C POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE'

# Stack script starts sysbox-mgr, sysbox-fs, containerd, dockerd; sends READY once sockets
# are up; then monitors. ExecStartPost gates systemctl-start on full API readiness so callers
# of "systemctl start" don't proceed until docker accepts connections.
ExecStart=${BIN_DIR}/dockyard-stack

# Wait until dockerd accepts API connections before systemctl start returns.
ExecStartPost=/bin/bash -c 'i=0; while ! ${BIN_DIR}/docker-cli -H unix://${DOCKER_SOCKET} info >/dev/null 2>&1; do i=\$((i+1)); [ \$i -ge 360 ] && exit 1; sleep 0.5; done'

# Apply isolation rules from ${ETC_DIR}/isolation.d/ if any .rules files exist.
# Each .rules file lists IPs to ACCEPT; all other intra-bridge traffic is DROPped.
# The chain name is DOCKYARD-ISOLATION and the jump rule is scoped to user-defined bridges.
ExecStartPost=-/bin/bash -c 'DOCKER=${BIN_DIR}/docker-cli; SOCK=unix://${DOCKER_SOCKET}; dir=${ETC_DIR}/isolation.d; ls "\$dir"/*.rules >/dev/null 2>&1 || exit 0; for net in \$(\$DOCKER -H \$SOCK network ls --filter driver=bridge --format "{{.Name}}" 2>/dev/null); do [ "\$net" = "bridge" ] && continue; net_id=\$(\$DOCKER -H \$SOCK network inspect "\$net" --format "{{.Id}}" 2>/dev/null | head -c 12) || continue; br="br-\${net_id}"; ip link show "\$br" &>/dev/null || continue; iptables -L DOCKYARD-ISOLATION >/dev/null 2>&1 || iptables -N DOCKYARD-ISOLATION; iptables -F DOCKYARD-ISOLATION; iptables -A DOCKYARD-ISOLATION -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; for f in "\$dir"/*.rules; do [ -f "\$f" ] || continue; while IFS= read -r ip; do [ -n "\$ip" ] || continue; iptables -A DOCKYARD-ISOLATION -s "\$ip" -j ACCEPT; iptables -A DOCKYARD-ISOLATION -d "\$ip" -j ACCEPT; done < "\$f"; done 2>/dev/null; iptables -A DOCKYARD-ISOLATION -j DROP; iptables -C FORWARD -i "\$br" -o "\$br" -j DOCKYARD-ISOLATION 2>/dev/null || iptables -I FORWARD -i "\$br" -o "\$br" -j DOCKYARD-ISOLATION; done'

# Clean up docker/containerd sockets
ExecStopPost=-/bin/rm -f ${DOCKER_SOCKET} ${CONTAINERD_SOCKET}

# Remove iptables rules (bridge)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null'

# Remove iptables rules (user-defined networks)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE 2>/dev/null'

# Remove isolation chain and its jump rules from all user-defined bridges
ExecStopPost=-/bin/bash -c 'for br in \$(ip -o link show type bridge 2>/dev/null | grep -oP "br-[0-9a-f]+"); do iptables -D FORWARD -i "\$br" -o "\$br" -j DOCKYARD-ISOLATION 2>/dev/null; done; iptables -F DOCKYARD-ISOLATION 2>/dev/null; iptables -X DOCKYARD-ISOLATION 2>/dev/null'

# Remove bridge
ExecStopPost=-/bin/bash -c 'if ip link show ${BRIDGE} &>/dev/null; then ip link set ${BRIDGE} down 2>/dev/null; ip link delete ${BRIDGE} 2>/dev/null; fi'

# Clean up sysbox run dir
ExecStopPost=-/bin/rm -rf ${SYSBOX_RUN_DIR}

TimeoutStartSec=180
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
SERVICEEOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    echo "  enabled ${SERVICE_NAME}.service (will start on boot)"
    echo ""
    echo "  sudo systemctl start ${SERVICE_NAME}    # start"
    echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
}

cmd_disable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "Stopping ${SERVICE_NAME}..."
            systemctl stop "${SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SERVICE_FILE"
        echo "Removed ${SERVICE_FILE}"
    else
        echo "Warning: ${SERVICE_FILE} does not exist." >&2
    fi

    systemctl daemon-reload
}

cmd_start() {
    require_root

    export PATH="${BIN_DIR}:${PATH}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "${RUN_DIR}/containerd" "$DOCKER_DATA/containerd"

    # Clean up stale sockets/pids from previous runs
    rm -f "$CONTAINERD_SOCKET" "$DOCKER_SOCKET"
    rm -f "${SYSBOX_RUN_DIR}/sysmgr.sock" "${SYSBOX_RUN_DIR}/sysfs.sock" "${SYSBOX_RUN_DIR}/sysfs-seccomp.sock"
    for pidfile in "${RUN_DIR}/containerd.pid" "${RUN_DIR}/dockerd.pid"; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            kill "$pid" 2>/dev/null && sleep 1 || true
            rm -f "$pidfile"
        fi
    done

    # Cleanup helper: kill previously started daemons on failure
    STARTED_PIDS=()
    cleanup() {
        echo "Startup failed — cleaning up..."
        for pid in "${STARTED_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        exit 1
    }

    # --- 1. Start per-instance sysbox daemons ---
    mkdir -p "$SYSBOX_RUN_DIR" "$SYSBOX_DATA_DIR"

    echo "Starting sysbox-mgr..."
    "${BIN_DIR}/sysbox-mgr" --run-dir "${SYSBOX_RUN_DIR}" --data-root "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-mgr.log" &
    SYSBOX_MGR_PID=$!
    echo "$SYSBOX_MGR_PID" > "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    STARTED_PIDS+=("$SYSBOX_MGR_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysmgr.sock" "sysbox-mgr" 60 || cleanup
    kill -0 "$SYSBOX_MGR_PID" 2>/dev/null || { echo "sysbox-mgr exited unexpectedly" >&2; cleanup; }
    echo "  sysbox-mgr ready (pid ${SYSBOX_MGR_PID})"

    echo "Starting sysbox-fs..."
    "${BIN_DIR}/sysbox-fs" --run-dir "${SYSBOX_RUN_DIR}" --mountpoint "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-fs.log" &
    SYSBOX_FS_PID=$!
    echo "$SYSBOX_FS_PID" > "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
    STARTED_PIDS+=("$SYSBOX_FS_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysfs.sock" "sysbox-fs" 60 || cleanup
    kill -0 "$SYSBOX_FS_PID" 2>/dev/null || { echo "sysbox-fs exited unexpectedly" >&2; cleanup; }
    echo "  sysbox-fs ready (pid ${SYSBOX_FS_PID})"

    # --- 2. Create bridge ---
    if ! ip link show "$BRIDGE" &>/dev/null; then
        echo "Creating bridge ${BRIDGE}..."
        ip link add "$BRIDGE" type bridge
        ip addr add "$DOCKYARD_BRIDGE_CIDR" dev "$BRIDGE"
        ip link set "$BRIDGE" up
    else
        echo "Bridge ${BRIDGE} already exists"
    fi

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Bridge rules (idempotent)
    iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE

    # Pool rules
    iptables -C FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -C FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE

    # --- 3. Start containerd ---
    echo "Starting containerd..."
    "${BIN_DIR}/containerd" \
        --root "$DOCKER_DATA/containerd" \
        --state "${RUN_DIR}/containerd" \
        --address "$CONTAINERD_SOCKET" \
        &>"${LOG_DIR}/containerd.log" &
    CONTAINERD_PID=$!
    echo "$CONTAINERD_PID" > "${RUN_DIR}/containerd.pid"
    STARTED_PIDS+=("$CONTAINERD_PID")

    wait_for_file "$CONTAINERD_SOCKET" "containerd" || cleanup
    echo "  containerd ready (pid ${CONTAINERD_PID})"

    # --- 4. Start dockerd ---
    echo "Starting dockerd..."
    "${BIN_DIR}/dockerd" \
        --config-file "${ETC_DIR}/daemon.json" \
        --containerd "$CONTAINERD_SOCKET" \
        --data-root "$DOCKER_DATA" \
        --exec-root "$RUN_DIR" \
        --pidfile "${RUN_DIR}/dockerd.pid" \
        --bridge "$BRIDGE" \
        --fixed-cidr "$DOCKYARD_FIXED_CIDR" \
        --default-address-pool "base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE}" \
        --host "unix://${DOCKER_SOCKET}" \
        --iptables=false \
        --group "${INSTANCE_GROUP}" \
        &>"${LOG_DIR}/dockerd.log" &
    DOCKERD_PID=$!
    STARTED_PIDS+=("$DOCKERD_PID")

    wait_for_file "$DOCKER_SOCKET" "dockerd" 30 || cleanup
    echo "  dockerd ready (pid ${DOCKERD_PID})"

    # Apply isolation rules from ${ETC_DIR}/isolation.d/ if any .rules files exist.
    local isolation_dir="${ETC_DIR}/isolation.d"
    if ls "${isolation_dir}"/*.rules >/dev/null 2>&1; then
        for net in $("${BIN_DIR}/docker-cli" -H "unix://${DOCKER_SOCKET}" network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null); do
            [ "$net" = "bridge" ] && continue
            local net_id
            net_id=$("${BIN_DIR}/docker-cli" -H "unix://${DOCKER_SOCKET}" network inspect "$net" \
                --format '{{.Id}}' 2>/dev/null | head -c 12) || continue
            local br="br-${net_id}"
            ip link show "$br" &>/dev/null || continue

            iptables -L DOCKYARD-ISOLATION >/dev/null 2>&1 || iptables -N DOCKYARD-ISOLATION
            iptables -F DOCKYARD-ISOLATION
            iptables -A DOCKYARD-ISOLATION -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            if [ -d "${isolation_dir}" ]; then
                for f in "${isolation_dir}"/*.rules; do
                    [ -f "$f" ] || continue
                    while IFS= read -r ip; do
                        [ -n "$ip" ] || continue
                        iptables -A DOCKYARD-ISOLATION -s "$ip" -j ACCEPT
                        iptables -A DOCKYARD-ISOLATION -d "$ip" -j ACCEPT
                    done < "$f"
                done
            fi
            iptables -A DOCKYARD-ISOLATION -j DROP
            iptables -C FORWARD -i "$br" -o "$br" -j DOCKYARD-ISOLATION 2>/dev/null ||
                iptables -I FORWARD -i "$br" -o "$br" -j DOCKYARD-ISOLATION
            echo "  isolation rules applied on ${br}"
        done
    fi

    echo "=== All daemons started ==="
    echo "Run: DOCKER_HOST=unix://${DOCKER_SOCKET} docker ps"
}

cmd_stop() {
    require_root

    # Reverse startup order: dockerd -> containerd -> sysbox
    stop_daemon dockerd "${RUN_DIR}/dockerd.pid" 20
    stop_daemon containerd "${RUN_DIR}/containerd.pid" 10
    stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
    stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
    rm -rf "$SYSBOX_RUN_DIR"

    # Clean up sockets
    rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"

    # Remove iptables rules (bridge)
    iptables -D FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null || true
    # Remove iptables rules (pool)
    iptables -D FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null || true

    # Remove isolation chain and its jump rules from all user-defined bridges
    for br in $(ip -o link show type bridge 2>/dev/null | grep -oP 'br-[0-9a-f]+'); do
        iptables -D FORWARD -i "$br" -o "$br" -j DOCKYARD-ISOLATION 2>/dev/null || true
    done
    iptables -F DOCKYARD-ISOLATION 2>/dev/null || true
    iptables -X DOCKYARD-ISOLATION 2>/dev/null || true

    # Remove bridge
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link set "$BRIDGE" down
        ip link delete "$BRIDGE"
        echo "Bridge ${BRIDGE} removed"
    fi

    # Remove leftover user-defined network bridges from the pool range
    cleanup_pool_bridges

    echo "=== All daemons stopped ==="
}

cmd_status() {
    echo "=== Dockyard Docker Status ==="
    echo ""

    echo "Variables:"
    echo "  DOCKYARD_ROOT=${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}"
    echo ""

    echo "Derived:"
    echo "  RUN_DIR=${RUN_DIR}"
    echo "  BRIDGE=${BRIDGE}"
    echo "  SERVICE_NAME=${SERVICE_NAME}"
    echo "  DOCKER_SOCKET=${DOCKER_SOCKET}"
    echo "  CONTAINERD_SOCKET=${CONTAINERD_SOCKET}"
    echo ""

    # --- systemd services ---
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "systemd (docker): $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown") ($(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown"))"
    else
        echo "systemd (docker): not installed"
    fi

    # --- pid checks ---
    check_pid() {
        local name="$1"
        local pidfile="$2"
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            if [ -d "/proc/${pid}" ]; then
                echo "${name}: running (pid ${pid})"
            else
                echo "${name}: dead (stale pid ${pid})"
            fi
        else
            echo "${name}: not running"
        fi
    }

    check_pid "sysbox-mgr" "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    check_pid "sysbox-fs " "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
    check_pid "containerd" "${RUN_DIR}/containerd.pid"
    check_pid "dockerd   " "${RUN_DIR}/dockerd.pid"

    # --- bridge ---
    if ip link show "$BRIDGE" &>/dev/null; then
        local local_ip
        local_ip=$(ip -4 addr show "$BRIDGE" 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "no ip")
        echo "bridge:     ${BRIDGE} (${local_ip})"
    else
        echo "bridge:     ${BRIDGE} not found"
    fi

    # --- sockets ---
    if [ -e "$DOCKER_SOCKET" ]; then
        echo "socket:     ${DOCKER_SOCKET}"
    else
        echo "socket:     ${DOCKER_SOCKET} not found"
    fi

    if [ -e "$CONTAINERD_SOCKET" ]; then
        echo "containerd: ${CONTAINERD_SOCKET}"
    else
        echo "containerd: ${CONTAINERD_SOCKET} not found"
    fi

    # --- connectivity test ---
    echo ""
    echo "Connectivity:"
    if [ -e "$DOCKER_SOCKET" ]; then
        echo "  DOCKER_HOST=unix://${DOCKER_SOCKET} docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de'"
        DOCKER_HOST="unix://${DOCKER_SOCKET}" docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de' 2>&1 | sed 's/^/  /'
    else
        echo "  skipped (docker socket not found)"
    fi

    # --- paths ---
    echo ""
    echo "Paths:"
    echo "  root:     ${DOCKYARD_ROOT}"
    echo "  data:     ${DOCKER_DATA}"
    echo "  logs:     ${LOG_DIR}"
}

cmd_destroy() {
    local YES=false
    local KEEP_DATA=false
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)       YES=true ;;
            --keep-data|-k) KEEP_DATA=true ;;
            -h|--help)      usage ;;
        esac
    done

    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [[ "$KEEP_DATA" == true ]]; then
        echo "This will remove the dockyard instance (binaries and config only — data preserved):"
        echo "  ${SERVICE_FILE}"
        echo "  ${DOCKYARD_ROOT}/  (except ${DOCKER_DATA}/)"
    else
        echo "This will remove all installed dockyard docker files:"
        echo "  ${SERVICE_FILE}    (docker systemd service)"
        echo "  ${DOCKYARD_ROOT}/  (all instance data: binaries, config, data, logs, sockets)"
        local data_size
        data_size=$(du -sh "${DOCKER_DATA}" 2>/dev/null | cut -f1 || echo "unknown")
        echo ""
        echo "Warning: this will permanently delete container data:"
        echo "  ${DOCKER_DATA}/  (~${data_size})"
        echo "  Use --keep-data (-k) to preserve container data."
    fi
    echo ""
    if [[ "$YES" != true ]]; then
        read -p "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # --- 1. Stop and remove systemd service (or stop daemons directly) ---
    if [ -f "$SERVICE_FILE" ]; then
        cmd_disable
    else
        # No systemd service — stop daemons directly
        for pidfile in "${RUN_DIR}/dockerd.pid" "${RUN_DIR}/containerd.pid"; do
            if [ -f "$pidfile" ]; then
                local pid
                pid=$(cat "$pidfile")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Stopping pid ${pid}..."
                    kill "$pid" 2>/dev/null || true
                fi
                rm -f "$pidfile"
            fi
        done
        stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
        stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
        rm -rf "$SYSBOX_RUN_DIR"
        rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        sleep 2
    fi

    # --- 1.5. Remove leftover user-defined network bridges from the pool ---
    cleanup_pool_bridges

    # --- 2. Remove AppArmor fusermount3 entry for this instance ---
    local apparmor_file="/etc/apparmor.d/local/fusermount3"
    local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
    if grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
        {
            flock -x 9
            awk -v start="$apparmor_begin" \
                -v stop="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end" \
                '$0 == start { skip=1 } skip { if ($0 == stop) { skip=0 }; next } { print }' \
                "$apparmor_file" > "${apparmor_file}.tmp" \
                && mv "${apparmor_file}.tmp" "$apparmor_file"
        } 9>"${apparmor_file}.lock"
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3 2>/dev/null || true
        fi
        echo "Removed AppArmor fusermount3 entry for ${DOCKYARD_DOCKER_PREFIX}"
    fi

    # --- 3. Remove instance root (selective or full) ---
    if [ -d "$DOCKYARD_ROOT" ]; then
        if [[ "$KEEP_DATA" == true ]]; then
            rm -rf "${DOCKYARD_ROOT}/bin"
            rm -rf "${DOCKYARD_ROOT}/etc"
            rm -rf "${DOCKYARD_ROOT}/log"
            rm -rf "${DOCKYARD_ROOT}/run"
            rm -rf "${DOCKYARD_ROOT}/lib/sysbox"
            rm -rf "${DOCKYARD_ROOT}/lib/docker-config"
            echo "Removed instance files from ${DOCKYARD_ROOT}/"
            echo "Data preserved at ${DOCKER_DATA}"
        else
            rm -rf "$DOCKYARD_ROOT"
            echo "Removed ${DOCKYARD_ROOT}/"
        fi
    fi

    # --- 4. Remove instance user and group ---
    if getent passwd "${INSTANCE_USER}" &>/dev/null; then
        userdel "${INSTANCE_USER}" 2>/dev/null || true
        echo "Removed user ${INSTANCE_USER}"
    fi
    if getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupdel "${INSTANCE_GROUP}" 2>/dev/null || true
        echo "Removed group ${INSTANCE_GROUP}"
    fi

    echo ""
    echo "=== Uninstall complete ==="
}

# ── Verify ───────────────────────────────────────────────────────────────────
# Smoke-tests a running dockyard instance: service, socket, API, containers,
# outbound networking, and Docker-in-Docker (sysbox).
# Exits 0 only when every check passes.

cmd_verify() {
    local _p=0 _f=0
    local _d="${BIN_DIR}/docker"
    local _s="unix://${DOCKER_SOCKET}"
    local out

    _pass() { echo "  PASS: $1"; _p=$((_p + 1)); }
    _fail() { echo "  FAIL: $1 — $2" >&2; _f=$((_f + 1)); }

    echo "=== dockyard verify: ${SERVICE_NAME} ==="
    echo ""

    # 1. systemd service active
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        _pass "systemd service ${SERVICE_NAME} active"
    else
        _fail "systemd service" "${SERVICE_NAME} is $(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo unknown)"
    fi

    # 2. docker socket exists
    if [ -S "${DOCKER_SOCKET}" ]; then
        _pass "docker socket exists"
    else
        _fail "docker socket" "${DOCKER_SOCKET} not found"
    fi

    # 3. docker info (API reachable)
    if DOCKER_HOST="$_s" "$_d" info >/dev/null 2>&1; then
        _pass "docker info (API reachable)"
    else
        out=$(DOCKER_HOST="$_s" "$_d" info 2>&1 | tail -2)
        _fail "docker info" "$out"
    fi

    # 4. basic container run
    out=$(DOCKER_HOST="$_s" "$_d" run --rm alpine echo verify-ok 2>&1)
    if echo "$out" | grep -q "verify-ok"; then
        _pass "container run (alpine echo)"
    else
        _fail "container run" "$out"
    fi

    # 5. outbound networking
    if DOCKER_HOST="$_s" "$_d" run --rm alpine ping -c3 -W2 1.1.1.1 >/dev/null 2>&1; then
        _pass "outbound networking (ping 1.1.1.1)"
    else
        _fail "outbound networking" "ping 1.1.1.1 failed from container"
    fi

    # 6. Docker-in-Docker via sysbox
    local cname="dockyard-verify-$$"
    DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
    if DOCKER_HOST="$_s" "$_d" run -d --name "$cname" docker:26.1-dind >/dev/null 2>&1; then
        local ready=false i
        for i in $(seq 1 30); do
            if DOCKER_HOST="$_s" "$_d" exec "$cname" docker info >/dev/null 2>&1; then
                ready=true
                break
            fi
            sleep 2
        done
        if $ready; then
            # Preload alpine from host cache to avoid Docker Hub rate limits.
            if [ -f /var/tmp/alpine.tar ]; then
                DOCKER_HOST="$_s" "$_d" exec -i "$cname" docker load < /var/tmp/alpine.tar >/dev/null 2>&1 || true
            fi
            out=$(DOCKER_HOST="$_s" "$_d" exec "$cname" docker run --rm alpine echo dind-ok 2>&1)
            if echo "$out" | grep -q "dind-ok"; then
                _pass "Docker-in-Docker (inner container via sysbox)"
            else
                _fail "DinD inner container" "$out"
            fi
        else
            _fail "DinD" "inner dockerd not ready after 60s"
        fi
        DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
    else
        out=$(DOCKER_HOST="$_s" "$_d" run --name "$cname" docker:26.1-dind 2>&1 | head -3)
        DOCKER_HOST="$_s" "$_d" rm -f "$cname" >/dev/null 2>&1 || true
        _fail "DinD" "could not start docker:26.1-dind — $out"
    fi

    echo ""
    if [ "$_f" -eq 0 ]; then
        echo "All ${_p} checks passed."
    else
        echo "${_p} passed, ${_f} failed."
    fi
    return "$_f"
}

# ── Usage ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./dockyard.sh <command> [options]

Commands:
  gen-env     Generate a conflict-free dockyard.env config file
  create      Download binaries, install config, set up systemd, start daemon
  enable      Install systemd service for this instance
  disable     Remove systemd service for this instance
  start       Start daemons manually (without systemd)
  stop        Stop manually started daemons
  status      Show instance status
  verify      Smoke-test a running instance (service, containers, DinD, networking)
  destroy     Stop and remove everything

All commands except gen-env require a config file:
  1. $DOCKYARD_ENV (if set)
  2. ./dockyard.env (in current directory)
  3. ../etc/dockyard.env (relative to script — for installed copy)
  4. $DOCKYARD_ROOT/etc/dockyard.env

Examples:
  ./dockyard.sh gen-env
  sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  sudo ./dockyard.sh start
  sudo ./dockyard.sh stop
  ./dockyard.sh status
  sudo ./dockyard.sh verify
  sudo ./dockyard.sh destroy
  sudo ./dockyard.sh destroy --keep-data   # preserve container data

  # Multiple instances
  DOCKYARD_DOCKER_PREFIX=test_ DOCKYARD_ROOT=/test ./dockyard.sh gen-env
  DOCKYARD_ENV=./dockyard.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

gen_env_usage() {
    cat <<'EOF'
Usage: ./dockyard.sh gen-env [OPTIONS]

Generate a dockyard.env config file with randomized, conflict-free networks.

Options:
  --nocheck     Skip all conflict checks
  -h, --help    Show this help

Output: ./dockyard.env (or $DOCKYARD_ENV if set). Errors if file exists.

Override any variable via environment:
  DOCKYARD_ROOT           Installation root (default: /dockyard)
  DOCKYARD_DOCKER_PREFIX  Prefix for bridge/service (default: dy_)
  DOCKYARD_BRIDGE_CIDR    Bridge IP/mask (default: random from 172.16.0.0/12)
  DOCKYARD_FIXED_CIDR     Container subnet (default: derived from bridge)
  DOCKYARD_POOL_BASE      Address pool base (default: random from 172.16.0.0/12)
  DOCKYARD_POOL_SIZE      Pool subnet size (default: 24)

Examples:
  ./dockyard.sh gen-env
  DOCKYARD_DOCKER_PREFIX=test_ ./dockyard.sh gen-env
  DOCKYARD_ROOT=/docker2 DOCKYARD_DOCKER_PREFIX=d2_ ./dockyard.sh gen-env
  ./dockyard.sh gen-env --nocheck
EOF
    exit 0
}

create_usage() {
    cat <<'EOF'
Usage: sudo ./dockyard.sh create [OPTIONS]

Create a dockyard instance: download binaries, install config,
set up systemd service, and start the daemon.

Requires a dockyard.env config file (run gen-env first).

Options:
  --no-systemd    Skip systemd service installation
  --no-start      Don't start the daemon after install
  -h, --help      Show this help

Examples:
  ./dockyard.sh gen-env && sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  DOCKYARD_ENV=./custom.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

# ── Dispatch ─────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    gen-env)
        cmd_gen_env "$@"
        ;;
    create)
        if ! try_load_env; then
            echo "No config found — auto-generating with random networks..."
            cmd_gen_env
            load_env
        fi
        derive_vars
        cmd_create "$@"
        ;;
    enable)
        load_env
        derive_vars
        cmd_enable
        ;;
    disable)
        load_env
        derive_vars
        cmd_disable
        ;;
    start)
        load_env
        derive_vars
        cmd_start
        ;;
    stop)
        load_env
        derive_vars
        cmd_stop
        ;;
    status)
        load_env
        derive_vars
        cmd_status
        ;;
    verify)
        load_env
        derive_vars
        cmd_verify
        ;;
    destroy)
        load_env
        derive_vars
        cmd_destroy "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        ;;
esac

