# Session Context

## User Prompts

### Prompt 1

Loading /sandcastle/etc/dockyard.env...
Installing dockyard docker...
  DOCKYARD_ROOT:          /sandcastle
  DOCKYARD_DOCKER_PREFIX: sc_
  DOCKYARD_BRIDGE_CIDR:   172.42.89.1/24
  DOCKYARD_FIXED_CIDR:    172.42.89.0/24
  DOCKYARD_POOL_BASE:     172.89.0.0/16
  DOCKYARD_POOL_SIZE:     24

  bridge:      sc_docker0
  exec-root:   /run/sc_docker
  service:     sc_docker.service
  runtime:     /sandcastle/docker-runtime
  data:        /sandcastle/docker
  socket:      /sandcastle/docker.sock

Downl...

### Prompt 2

in installer: if $SANDCASTLE_HOME is BTRFS - create btrfs subvolumnes for /sandcastle/data/* and /sandcastle/docker

### Prompt 3

also in sandcaste if the underlying fs is BTRFS create subvolumnes for /sandcastle/data/users/<username> and the users data dir. how can we do that without being root

### Prompt 4

add passwordless sudo just for btrfs commands!

