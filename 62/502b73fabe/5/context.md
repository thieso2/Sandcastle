# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Add `mkcert` TLS Mode

## Context

Currently Sandcastle has two TLS modes:
- **`selfsigned`** — `openssl` generates a self-signed cert. Traefik serves it from `/data/certs/cert.pem`. Browser always shows an "untrusted" warning.
- **`letsencrypt`** — ACME via Let's Encrypt. Requires a public domain and ACME email. Not usable on private networks.

There's a gap: users on private networks or homelabs who want browser-trusted HTTPS without a public domain. ...

### Prompt 2

how to use serfsigend mode with deploy:local

### Prompt 3

in letsencrypt mode i do not need to provide any certs - tez app provided te hostname(s) and treafik with letsencrypt does the rest. in selfsigned mode the app should provide the hostname  _and_ a selfsiged cert to traefik.

### Prompt 4

route_manager.rb — auto-generate the cert via mkcert!

### Prompt 5

One thing to be aware of: mkcert must be present in the Rails container for this to work in deploy:local. In production the installer already runs mkcert on the host
  before the containers start, so the cert exists and the Rails code takes the early return — mkcert in the container is never called.

### Prompt 6

what is the full config for the deploy:local container?

### Prompt 7

what is the full config for the deploy:local container?  what hostname etc

### Prompt 8

lets change name from sandcastle.tc to dev.sand

### Prompt 9

~/Projects/GitHub/Sandcastle [main] % curl -v https://dev.sand:8443/session/new
* Host dev.sand:8443 was resolved.
* IPv6: ::1
* IPv4: 127.0.0.1
*   Trying [::1]:8443...
* Connected to dev.sand (::1) port 8443
* ALPN: curl offers h2,http/1.1
* (304) (OUT), TLS handshake, Client hello (1):
*  CAfile: /etc/ssl/cert.pem
*  CApath: none
* (304) (IN), TLS handshake, Server hello (2):
* (304) (IN), TLS handshake, Unknown (8):
* (304) (IN), TLS handshake, Certificate (11):
* SSL certificate problem: un...

### Prompt 10

commit this

### Prompt 11

when tailscale is connected -> return to dashboard with a flash saying that tailscale is now connected!

### Prompt 12

commit this

