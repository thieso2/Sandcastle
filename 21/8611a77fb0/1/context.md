# Session Context

## User Prompts

### Prompt 1

the flash layout is broken:

### Prompt 2

SANDCASTLE_USER was not saved on install!

### Prompt 3

the SANDCASTLE_ADMIN_USER is not stored in the db on setup!

### Prompt 4

create mise task to reset local docker coompse env

### Prompt 5

commit these fixes

### Prompt 6

what is teh default user/pw created on deploy?

### Prompt 7

for the lcoal docker deploy and also bin/dev change the port to 4000

### Prompt 8

mise run deploy:local:reset shoudl also delete theg wetty container!

### Prompt 9

~/Projects/GitHub/Sandcastle [main] % mise run deploy:local:reset
[deploy:local:reset] ERROR Failed to render task script: #!/usr/bin/env bash
set -euo pipefail

echo "Removing WeTTY containers..."
docker ps -a --filter "name=sc-wetty-" --format "{{.Names}}" | xargs -r docker rm -f || true

echo "Removing Tailscale containers..."
docker ps -a --filter "name=sc-ts-" --format "{{.Names}}" | xargs -r docker rm -f || true

echo "Stopping and removing containers, volumes, and networks..."
docker comp...

### Prompt 10

run and debug "mise run deploy:local:reset"

### Prompt 11

whats the admin user and PW after mise run deploy:local

### Prompt 12

flash should be centred!

### Prompt 13

commit these changes

