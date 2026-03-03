# Session Context

## User Prompts

### Prompt 1

analyze and debug why VERBOSE=1 sandcastle connect test does not work.

### Prompt 2

[Request interrupted by user]

### Prompt 3

it cannot connect to the tailscale ip. why?
see sandcastle list

### Prompt 4

use tailscale status to find out.
i reinstalled sandcastle on sandman - maybe the subnet has changed but tailscale thinks its the old one?
debug!

### Prompt 5

why does the sidecar subnet change? we should have that in the sandcaste-env so utr stays stable!
also add a sandcaste name to the env. that shold be used for the tailscale host name. if not set use the hostname. the tailscale machinename shoudl be sc-{sandcastle name (replace ' ' witz '-'}

