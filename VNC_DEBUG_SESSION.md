# VNC Debug Session - 2026-02-15

## Issues Found & Fixed

### 1. Port Mismatch in VncManager ✅ FIXED

**Problem:** VncManager was trying to connect to noVNC container on port 8080, but noVNC actually listens on port 6080.

**Fix:** Updated `app/services/vnc_manager.rb:223`

```ruby
# Before:
"servers" => [ { "url" => "http://#{container_name}:8080" } ]

# After:
"servers" => [ { "url" => "http://#{container_name}:6080" } ]
```

**Also updated:** Existing Traefik config `/data/traefik/dynamic/vnc-38.yml` to use port 6080.

### 2. Missing VNC Server in Sandbox Container ⏳ PENDING

**Problem:** Running sandbox containers use old image (`ghcr.io/thieso2/sandcastle-sandbox:latest`) that doesn't have VNC tools (Xvfb, x11vnc) installed.

**Root Cause:** The sandbox Dockerfile includes VNC installation, but deployed containers are using an older image version built before VNC support was added.

**Fix Applied:** Updated `images/sandbox/Dockerfile` to install VNC tools:

```dockerfile
# GUI tools: Xvfb (virtual X server) and x11vnc for browser access
RUN apt-get update && apt-get install -y \
    xvfb x11vnc xfonts-base xfonts-100dpi xfonts-75dpi \
    xterm fluxbox \
    && rm -rf /var/lib/apt/lists/*
```

**Note:** Chrome installation commented out due to dependency conflicts with Ubuntu 25.10.

### 3. Traefik Configuration ✅ WORKING

**Status:** Traefik dynamic config exists and is properly configured. The VNC routing works correctly after the port fix.

## What Works

- ✅ noVNC container runs and listens on port 6080
- ✅ Traefik routing configured with forwardAuth middleware
- ✅ Authentication flow (`VncController#auth`) works correctly
- ✅ VncManager service logic is sound (after port fix)
- ✅ Web container restarted to apply code changes

## What's Missing

- ⏳ VNC server (Xvfb + x11vnc) running in sandbox containers
- ⏳ Rebuild sandbox image with VNC tools
- ⏳ Recreate sandbox with new image

## Next Steps to Enable VNC

### 1. Rebuild Sandbox Image

```bash
cd images/sandbox
docker build -t sandcastle-sandbox:latest .
```

**Note:** This may take 10-15 minutes due to Docker installation step. Network speed affects build time.

### 2. Verify VNC Tools in Image

```bash
docker run --rm sandcastle-sandbox:latest bash -c \
  'command -v Xvfb && command -v x11vnc && echo "✓ VNC tools installed"'
```

Should output:
```
/usr/bin/Xvfb
/usr/bin/x11vnc
✓ VNC tools installed
```

### 3. Recreate Sandbox with New Image

Via Rails console:

```bash
docker exec -it sandcastle-web ./bin/rails runner "
  sandbox = Sandbox.find_by(name: 'quantum-viper')
  if sandbox
    user = sandbox.user
    persistent = sandbox.persistent_volume

    # Destroy old sandbox
    SandboxManager.new.destroy(sandbox: sandbox)

    # Create new sandbox with updated image
    SandboxManager.new.create(
      user: user,
      name: 'quantum-viper',
      image: 'sandcastle-sandbox:latest',
      persistent: persistent
    )
  end
"
```

Or via web UI:
1. Delete the sandbox
2. Create a new one with the same name

### 4. Test VNC Connection

1. Click the browser icon for the sandbox in the web UI
2. Wait for the "Connecting to browser..." page
3. Should redirect to noVNC interface showing the desktop

## Technical Details

### VNC Architecture

```
Browser
  ↓ HTTPS
Traefik (:8443)
  ↓ forwardAuth → VncController#auth (validates session)
  ↓ stripPrefix (/vnc/{id}/novnc)
noVNC Container (port 6080)
  ↓ VNC protocol (port 5900)
Sandbox Container
  ├─ Xvfb :99 (virtual X display)
  └─ x11vnc -display :99 -rfbport 5900
```

### Container Names

- noVNC: `sc-vnc-{user}-{sandbox}` (e.g., `sc-vnc-thies-quantum-viper`)
- Sandbox: `{user}-{sandbox}` (e.g., `thies-quantum-viper`)
- Network: `sandcastle-web` (bridge)

### VNC Server Startup

The sandbox entrypoint (`images/sandbox/entrypoint.sh:71-80`) automatically starts:

1. **Xvfb** on display :99 with 1920x1080 resolution
2. **x11vnc** listening on port 5900, connected to display :99

```bash
Xvfb :99 -screen 0 1920x1080x24 &>/var/log/xvfb.log &
sleep 1
DISPLAY=:99 x11vnc -shared -forever -nopw -rfbport 5900 &>/var/log/x11vnc.log &
```

### Debugging Commands

```bash
# Check if noVNC container is running
docker ps | grep sc-vnc

# Check noVNC logs
docker logs sc-vnc-thies-quantum-viper

# Check if VNC server is running in sandbox
docker exec thies-quantum-viper ps aux | grep -E "Xvfb|x11vnc"

# Check VNC server logs
docker exec thies-quantum-viper cat /var/log/xvfb.log
docker exec thies-quantum-viper cat /var/log/x11vnc.log

# Test VNC connection from sandbox to itself
docker exec thies-quantum-viper nc -zv localhost 5900

# Check Traefik config
docker exec sandcastle-web cat /data/traefik/dynamic/vnc-38.yml

# Check noVNC is listening on port 6080
docker exec sc-vnc-thies-quantum-viper netstat -tlnp | grep 6080
```

## Files Modified

1. `app/services/vnc_manager.rb` - Port fix (8080 → 6080)
2. `images/sandbox/Dockerfile` - Added VNC tools installation
3. `/data/traefik/dynamic/vnc-38.yml` - Runtime config update (port fix)

## Known Issues

### Ubuntu 25.10 + Chrome Compatibility

Chrome installation fails on Ubuntu 25.10 due to missing dependencies:
- `libatspi2.0-0:amd64`
- `libxdamage1:amd64`
- `libxext6:amd64`
- etc.

**Workaround:** Chrome installation commented out in Dockerfile. Users can install it manually if needed, or we can switch to Ubuntu 24.04 LTS for better package compatibility.

### Slow Package Downloads

During testing, apt-get package downloads were extremely slow (20+ minutes for a few packages). This affected both image builds and in-container installations.

**Recommendation:** Run builds during better network conditions or consider using Ubuntu package mirrors closer to your location.

## Testing Checklist

Once sandbox is recreated with new image:

- [ ] VNC button in web UI triggers `/sandboxes/{id}/vnc` POST
- [ ] Redirects to `/sandboxes/{id}/vnc/wait` waiting page
- [ ] Status polling (`/sandboxes/{id}/vnc/status`) returns "ready"
- [ ] Redirects to `/vnc/{id}/novnc` URL
- [ ] Traefik forwardAuth validates session
- [ ] noVNC interface loads in browser
- [ ] Can see Xvfb desktop (black screen is normal - no apps running)
- [ ] Can interact with desktop (right-click, open xterm, etc.)

## Additional Notes

- Web container was restarted to pick up VncManager code changes
- Existing VNC session for sandbox #38 should be closed and reopened after sandbox recreation
- The web container restart means the code fix is already live in the local environment
