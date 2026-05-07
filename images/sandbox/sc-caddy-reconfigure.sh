#!/usr/bin/env bash
#
# Regenerate /etc/sandcastle/caddy/certs/sandbox.{pem,key.pem} and
# /etc/caddy/Caddyfile from $SANDCASTLE_DNS_NAME and $SANDCASTLE_DNS_ALIASES,
# then reload Caddy if it's running. Invoked at sandbox startup by
# entrypoint.sh and on-demand by `docker exec` from Rails when aliases
# change, so the in-sandbox Caddy can pick up new hostnames without a
# container restart.
#
# Inputs:
#   SANDCASTLE_DNS_NAME      — sandbox FQDN (e.g. tubu.sc.sandman)
#   SANDCASTLE_DNS_ALIASES   — comma-separated alias names, already
#                              expanded into all left-prefix forms by
#                              Rails (e.g. "admin.tubu.sc.sandman,
#                              admin.tubu.sc,admin.tubu,admin")
set -euo pipefail

CADDY_DNS_NAME="${SANDCASTLE_DNS_NAME:-}"
if [ -z "$CADDY_DNS_NAME" ]; then
    echo "sc-caddy-reconfigure: SANDCASTLE_DNS_NAME unset; nothing to do" >&2
    exit 0
fi

if ! command -v caddy &>/dev/null || ! command -v mkcert &>/dev/null; then
    echo "sc-caddy-reconfigure: caddy or mkcert not installed" >&2
    exit 1
fi

install -d -m 0755 /etc/sandcastle/caddy/certs /var/log/caddy /var/lib/caddy /etc/caddy
install -d -m 0700 /etc/sandcastle/caddy/mkcert
export CAROOT=/etc/sandcastle/caddy/mkcert

# Build SAN + Caddy host lists. Every left-prefix form of CADDY_DNS_NAME
# is added with both itself and its one-label wildcard, so callers can
# hit short forms (tubu.sc.sandman → tubu.sc, tubu) and any single-label
# alias prefix lands on a wildcard. Then any explicit aliases (passed
# through from Rails) are appended verbatim — needed for bare-label forms
# like `admin` that no wildcard can match.
IFS=. read -ra _PARTS <<< "$CADDY_DNS_NAME"
SAN_ARGS=()
HOSTS_HTTP=""
HOSTS_HTTPS=""
for ((i=1; i<=${#_PARTS[@]}; i++)); do
    prefix=$(IFS=.; printf '%s' "${_PARTS[*]:0:i}")
    SAN_ARGS+=("$prefix" "*.$prefix")
    if [ -n "$HOSTS_HTTP" ]; then
        HOSTS_HTTP+=", "
        HOSTS_HTTPS+=", "
    fi
    HOSTS_HTTP+="http://$prefix, http://*.$prefix"
    HOSTS_HTTPS+="https://$prefix, https://*.$prefix"
done

if [ -n "${SANDCASTLE_DNS_ALIASES:-}" ]; then
    IFS=, read -ra _ALIASES <<< "$SANDCASTLE_DNS_ALIASES"
    for name in "${_ALIASES[@]}"; do
        [ -z "$name" ] && continue
        SAN_ARGS+=("$name")
        HOSTS_HTTP+=", http://$name"
        HOSTS_HTTPS+=", https://$name"
    done
fi

mkcert \
    -cert-file /etc/sandcastle/caddy/certs/sandbox.pem \
    -key-file /etc/sandcastle/caddy/certs/sandbox-key.pem \
    "${SAN_ARGS[@]}" \
    &>/var/log/caddy/mkcert.log || {
        echo "sc-caddy-reconfigure: mkcert failed" >&2
        exit 1
    }

cat > /etc/caddy/Caddyfile <<CADDYFILE
$HOSTS_HTTP {
    log {
        output file /var/log/caddy/access.log
    }
    reverse_proxy 127.0.0.1:3000 [::1]:3000 localhost:3000 {
        lb_try_duration 5s
        lb_try_interval 250ms
    }
}

$HOSTS_HTTPS {
    tls /etc/sandcastle/caddy/certs/sandbox.pem /etc/sandcastle/caddy/certs/sandbox-key.pem
    log {
        output file /var/log/caddy/access.log
    }
    reverse_proxy 127.0.0.1:3000 [::1]:3000 localhost:3000 {
        lb_try_duration 5s
        lb_try_interval 250ms
    }
}
CADDYFILE

# If Caddy is already running, hot-reload. Otherwise let the caller start
# it (entrypoint does that on first boot).
if pgrep -x caddy >/dev/null 2>&1; then
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
        >> /var/log/caddy/caddy.log 2>&1 || {
            echo "sc-caddy-reconfigure: caddy reload failed" >&2
            exit 1
        }
fi
