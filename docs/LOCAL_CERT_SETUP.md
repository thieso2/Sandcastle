# Setting Up Locally-Trusted Certificates

## Why mkcert?

The current self-signed certificate works but triggers browser warnings. `mkcert` creates certificates signed by a local Certificate Authority (CA) that your system trusts automatically.

## Setup Instructions

### 1. Install mkcert

```bash
brew install mkcert
```

### 2. Install the local CA in your system keychain

```bash
mkcert -install
```

This adds mkcert's CA to your system trust store. You may need to enter your password.

### 3. Generate certificates for sandcastle.local

```bash
./scripts/generate-local-cert.sh
```

Or manually:

```bash
cd /tmp/sandcastle-traefik-certs
mkcert \
  -cert-file cert.pem \
  -key-file key.pem \
  sandcastle.local \
  "*.sandcastle.local" \
  localhost \
  127.0.0.1 \
  ::1
```

### 4. Restart Traefik

```bash
mise run deploy:local
```

## Verification

After restarting, visit `https://sandcastle.local:8443/` in Chrome. The certificate should show:

- **Issued by:** mkcert (your username)
- **Valid:** Green padlock, no warnings
- **Trusted:** Certificate chain validates to your local CA

## Troubleshooting

### Certificate still shows as untrusted

1. Check mkcert CA is installed: `mkcert -CAROOT`
2. Verify CA is in keychain: `security find-certificate -c "mkcert"`
3. Restart Chrome completely (all windows closed)
4. Clear Chrome's certificate cache: chrome://net-internals/#hsts

### Wrong certificate being used

1. Check certificate files: `ls -la /tmp/sandcastle-traefik-certs/`
2. Verify Traefik config: `docker exec sandcastle-traefik-1 cat /data/dynamic/rails.yml`
3. Check Traefik logs: `docker compose -f docker-compose.local.yml logs traefik`
