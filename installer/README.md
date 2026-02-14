# Installer Build System

The `installer.sh` is **generated** from `installer.sh.in` template and source files.

## How It Works

```
installer.sh.in              # Template with @@TEMPLATE:file@@ markers
  + templates/*.yml          # Static config templates
  + docker-compose.yml.template  # Parameterized compose file
  + /docker/postgres/init-databases.sh  # Source file from repo
  ↓
  installer/build.sh         # Build script
  ↓
installer.sh                 # Generated installer (committed to repo)
```

## Quick Start

**Build installer.sh from template:**
```bash
mise run installer:build
```

**Validate installer.sh is up to date:**
```bash
mise run installer:validate
```

## File Structure

```
installer/
  installer.sh.in           # Template with @@TEMPLATE:markers@@
  build.sh                  # Generates installer.sh from template
  templates/                # Template files
    banner.sh               # Login banner for sandboxes
    docker-compose.yml.template  # Parameterized compose file
    docker-logs.sh          # Wrapper script
    dockyard.env.template   # Dockyard config
    sandcastle.env.template # User config template
    traefik-*.yml           # Traefik configs (letsencrypt/selfsigned)
    rails-*.yml             # Initial Rails routes
```

## Workflow

### Modifying installer logic

1. Edit `installer/installer.sh.in`
2. Run `mise run installer:build`
3. Test the generated `installer.sh`
4. Commit both files

### Modifying embedded files

**For template files (banner, traefik configs, etc.):**
1. Edit the file in `installer/templates/`
2. Run `mise run installer:build`
3. Commit both the template and generated installer.sh

**For source files (init-databases.sh):**
1. Edit `/docker/postgres/init-databases.sh`
2. Run `mise run installer:build`
3. Commit both files

**For docker-compose.yml:**
1. Edit `/docker-compose.yml` for local dev
2. Edit `installer/templates/docker-compose.yml.template` for deployment
3. Key differences:
   - Template uses `${APP_IMAGE}`, `${DATA_MOUNT}`, `${SANDCASTLE_HOME}`
   - Template escapes variables: `\${DB_PASSWORD}` (literal $ in output)
   - Template adds `runtime: runc` to services
4. Run `mise run installer:build`
5. Commit all three files

## Template Markers

In `installer.sh.in`, heredoc content is replaced with:
```bash
cat > "$file" <<MARKER
@@TEMPLATE:filename@@
MARKER
```

The build script replaces `@@TEMPLATE:filename@@` with the file contents.

Supported formats:
- `@@TEMPLATE:banner.sh@@` - from `installer/templates/banner.sh`
- `@@TEMPLATE:templates/file.yml@@` - explicit path
- `@@TEMPLATE:/docker/postgres/init.sh@@` - from repo root

## Pre-commit Hook

Add to `.git/hooks/pre-commit`:
```bash
#!/bin/bash
if ! mise run installer:validate; then
  echo "ERROR: Run 'mise run installer:build' before committing"
  exit 1
fi
```

## Why This System?

**Problem:** installer.sh embedded many files as heredocs, which got out of sync with source files (e.g., docker-compose.yml, init-databases.sh).

**Solution:**
- Single source of truth for each file
- Template-based generation prevents drift
- Validation task catches sync issues

## Migration Notes

Old system (pre-refactor):
- `installer.sh` - monolithic file with embedded heredocs
- Manual sync required when changing embedded files
- Frequent drift between dev and deployment configs

New system:
- `installer.sh.in` - template with markers
- `installer/build.sh` - automatic generation
- `mise run installer:build` - single command to rebuild
