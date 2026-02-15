# Session Context

## User Prompts

### Prompt 1

create SNADMAN.md woth completre deploy, explore, inspect and debug instructtions for my sancasele isntallation on sandman.

### Prompt 2

explain and debug what broke the network connectivity of the tailscale sc-ts-thies container. it used to work - what broke it?

### Prompt 3

also check ../dockyard for changes.

### Prompt 4

fix it

### Prompt 5

pull main with rebase

### Prompt 6

fix:

~/Projects/GitHub/Sandcastle [main] % VERBOSE=1 sandcastle create thies --home --data
server: hq (https://hq.sandcastle.rocks)
Server: hq (https://hq.sandcastle.rocks)
→ POST https://hq.sandcastle.rocks/api/sandboxes
  request: {"name":"thies","image":"ghcr.io/thieso2/sandcastle-sandbox:latest","mount_home":true,"data_path":"."}
← 201 (377 bytes)
  response: {"id":1,"name":"thies","full_name":"thies-thies","status":"pending","image":"ghcr.io/thieso2/sandcastle-sandbox:latest","ssh_port...

