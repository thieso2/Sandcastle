# Installation vs Uninstall Analysis

## Created During Installation

### System Configuration
- ✅ **User/Group** (`sandcastle:sandcastle`, UID/GID 220568)
  - Lines 776-791
  - **Cleanup:** Lines 651-659 (only if `CREATED_USER/CREATED_GROUP=true`)

- ✅ **Sudoers file** (`/etc/sudoers.d/sandcastle`)
  - Lines 178-195
  - **Cleanup:** Lines 669-673 ✅

- ✅ **Login banner** (`/etc/profile.d/sandcastle-banner.sh`)
  - Lines 223-266
  - **Cleanup:** Lines 688-691 ✅

- ❌ **UFW firewall rules** (ports 22, 80, 443, 2201-2299)
  - Lines 754-769
  - **Cleanup:** NOT REMOVED ❌

### User Home Directory Files
- ✅ **PATH configuration** (`~/.profile`, `~/.bashrc`)
  - Lines 197-227
  - **Cleanup:** Lines 675-688 ✅

- ⚠️ **SSH keys** (`~/.ssh/authorized_keys`)
  - Lines 143-173
  - **Cleanup:** NOT EXPLICITLY REMOVED (preserved with home dir)

### Dockyard (Docker + Sysbox)
- ✅ **Dockyard service** (systemd unit, Docker daemon)
  - Lines 724-752
  - **Cleanup:** Lines 635-649 ✅

- ✅ **Dockyard config** (`$SANDCASTLE_HOME/etc/dockyard.env`)
  - Lines 733-740
  - **Cleanup:** Line 695 (via `rm -rf $SANDCASTLE_HOME/etc`) ✅

### Data Directories
- ✅ **Directory structure**
  - Lines 271-303: `etc/`, `data/users/`, `data/sandboxes/`, `data/wetty/`, `data/traefik/`, `data/postgres/`
  - **Cleanup:**
    - `etc/` removed (line 695) ✅
    - `data/traefik/` removed (line 696) ✅
    - `data/users/`, `data/sandboxes/`, `data/postgres/` **PRESERVED** (user data, line 701-703) ⚠️

### Configuration Files
- ✅ **Runtime .env** (`$SANDCASTLE_HOME/.env`)
  - Lines 836-860
  - **Cleanup:** Line 693 ✅

- ✅ **Installed config** (`$SANDCASTLE_HOME/etc/sandcastle.env`)
  - Lines 889-922
  - **Cleanup:** Line 695 (via `rm -rf etc/`) ✅

- ✅ **Docker Compose** (`$SANDCASTLE_HOME/docker-compose.yml`)
  - Lines 385-508
  - **Cleanup:** Line 694 ✅

- ✅ **PostgreSQL init script** (`$SANDCASTLE_HOME/etc/postgres/init-databases.sh`)
  - Lines 1067-1082
  - **Cleanup:** Line 695 (via `rm -rf etc/`) ✅

- ✅ **Traefik config** (`$SANDCASTLE_HOME/data/traefik/traefik.yml`, `dynamic/rails.yml`)
  - Lines 924-1044
  - **Cleanup:** Line 696 (via `rm -rf data/traefik`) ✅

- ✅ **Helper scripts** (`docker-runtime/bin/docker-logs`)
  - Lines 376-383
  - **Cleanup:** Line 649 (Dockyard destroy removes docker-runtime) ✅

### Docker Resources
- ✅ **Docker network** (`sandcastle-web`)
  - Lines 1051-1056
  - **Cleanup:** Line 635 ✅

- ❌ **Docker images** (sandcastle, sandcastle-sandbox, traefik, postgres)
  - Lines 1059-1065
  - **Cleanup:** Line 633 uses `--rmi all` but only for compose services ⚠️
    - Sandbox image NOT removed (pulled separately)

- ✅ **Containers** (web, worker, postgres, traefik, migrate, sandboxes, Tailscale sidecars)
  - Lines 1090-1092
  - **Cleanup:** Lines 616-633 ✅

- ✅ **Tailscale networks** (`sc-ts-net-{username}`)
  - Automatic during sandbox creation
  - **Cleanup:** Lines 624-631 ✅

## Issues Found

### ❌ CRITICAL: User/Group Deletion Logic
**Current behavior:** Only deletes if `CREATED_USER=true` / `CREATED_GROUP=true`
**Problem:** If the installed config (`etc/sandcastle.env`) is missing or corrupted, the user/group won't be deleted
**Location:** Lines 651-659

### ❌ UFW Firewall Rules Not Reverted
**Created:** Lines 754-769 (ports 22, 80, 443, 2201-2299)
**Cleanup:** NOT REMOVED
**Impact:** Firewall rules persist after uninstall

### ⚠️ Sandbox Docker Image Not Removed
**Created:** Line 1062 (`$DOCKER pull "$SANDBOX_IMAGE"`)
**Cleanup:** `--rmi all` on line 633 only removes compose images (app, postgres, traefik)
**Impact:** Sandbox image persists, can be large (~1GB)

### ⚠️ User Home Directory Preserved
**Created:** `$SANDCASTLE_HOME` becomes user home (line 788, 301)
**Cleanup:** Home dir preserved (lines 697-703)
**Impact:** `.ssh/`, `.bashrc`, `.profile` persist even though PATH exports are removed

## Recommendations

1. ✅ **Always delete user/group** - Don't rely on `CREATED_USER/CREATED_GROUP` flags - FIXED
2. ✅ **Revert UFW rules** - Remove the ports we opened - FIXED
3. ✅ **Remove sandbox image** - Add explicit cleanup for sandbox image - FIXED
4. ✅ **Clean up /run/sc_docker** - Already done (line 699)
5. ✅ **Remove user home** - Using `userdel -r` to remove home directory - FIXED

## Changes Applied

### 1. User/Group Deletion (Lines 661-669)
- Changed from conditional deletion to always delete
- Added `-r` flag to `userdel` to remove home directory and mail spool
- Removes `.ssh/`, `.profile`, `.bashrc` automatically

### 2. UFW Firewall Cleanup (Lines 671-677)
- Added cleanup for HTTP, HTTPS, and SSH port range (2201-2299)
- Only runs if UFW is installed and active

### 3. Sandbox Image Removal (Lines 639-643)
- Explicitly removes `$SANDBOX_IMAGE` after containers are stopped
- `docker compose down --rmi all` only removes compose images (app, postgres, traefik)

### 4. SSH PATH Configuration
- PATH configured in `~/.profile` (for SSH non-interactive shells)
- PATH configured in `~/.bashrc` (for interactive shells)
- Home directory cleanup handled by `userdel -r`
