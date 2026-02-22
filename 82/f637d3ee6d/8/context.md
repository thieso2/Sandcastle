# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: TCP Port-Forward Routes

## Context

Routes currently support only HTTPS (layer 7, domain-based via Traefik `Host()` rules on port 443).
The new "tcp" mode adds layer-4 port forwarding: Traefik listens on a public port (e.g. 3000)
and forwards raw TCP to the container port. This is useful for databases, raw TCP services, or
anything that isn't HTTP. Port range: 3000–3099 (100 slots), pre-declared in the Traefik static
config and opened in UFW by the insta...

### Prompt 2

traefik needs to publish all thse ports to the host, right? hwo can i make tcp post reachable?

### Prompt 3

425ed11f5d6b   traefik:v3.3                     "/entrypoint.sh --en…"   42 seconds ago      Up 41 seconds             0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 0.0.0.0:8443->443/tcp, [::]:8443->443/tcp   sandcastle-traefik-1

### Prompt 4

we also need to fix deploy:local

### Prompt 5

how different are the deploy:local and ./installer.sh install structures?

### Prompt 6

now deploy local does not have a mkcert cert any more!
https://dev.sand:8443/ 
DEBUG AND FIX!

