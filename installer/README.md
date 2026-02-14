# Installer Build System

The installer.sh embeds several template files as heredocs. To prevent these from getting out of sync with source files, this directory contains:

## Structure

```
installer/
  templates/          # Extracted template files
    banner.sh         # Login banner shown in sandboxes
    docker-logs.sh    # Wrapper script for docker logs
    dockyard.env.template
    rails-letsencrypt.yml
    rails-selfsigned.yml
    sandcastle.env.template
    traefik-letsencrypt.yml
    traefik-selfsigned.yml
  build.sh            # Validates installer vs source files
  sync-files.sh       # Syncs source files into installer (USE WITH CAUTION)
  README.md           # This file
```

## Key Files and Their Sources

### docker-compose.yml
**Two versions exist:**
- **`/docker-compose.yml`**: Local development (hardcoded paths like `/data`)
- **Installer template** (line ~396): Deployment version (parameterized: `${DATA_MOUNT}`, `${APP_IMAGE}`)

**When to update:**
- Change local version: Update `/docker-compose.yml`
- Change deployment: Update installer.sh heredoc at line ~396
- **Always update both** when adding/removing services or environment variables

**Critical differences:**
- Installer uses `${APP_IMAGE}`, `${DATA_MOUNT}`, `${SANDCASTLE_HOME}` variables
- Installer escapes variables: `\${DB_PASSWORD}` (literal $ in output)
- Installer adds `runtime: runc` to prevent Sysbox conflicts

### docker/postgres/init-databases.sh
**Single source of truth:** `/docker/postgres/init-databases.sh`

The installer embeds this at line ~1085. Run `mise run installer:sync-postgres` to sync.

## Workflow

### When you modify docker-compose.yml

1. Update `/docker-compose.yml` for local development
2. Manually update the installer.sh heredoc (line ~396) with equivalent parameterized version
3. Run `mise run installer:validate` to check for other drift

### When you modify init-databases.sh

1. Update `/docker/postgres/init-databases.sh`
2. Run `installer/sync-postgres-init.sh` to sync into installer.sh (TODO: create this)

### Before releasing

```bash
mise run installer:validate
```

This will warn about any files that are out of sync.

## Future Improvements

- [ ] Create separate docker-compose.template.yml for deployment
- [ ] Build installer.sh from modular template files automatically
- [ ] Add pre-commit hook to validate sync status
- [ ] Generate both versions from a single source
