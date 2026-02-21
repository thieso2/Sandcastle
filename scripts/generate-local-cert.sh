#!/usr/bin/env bash
set -euo pipefail

# Generate a locally-trusted TLS certificate for deploy:local (dev.sand).
# The cert is stored in .local/certs/ and bind-mounted into the container,
# so it survives docker-compose resets.

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.local/certs"

if ! command -v mkcert &>/dev/null; then
  echo "Error: mkcert is not installed"
  echo "Install with: brew install mkcert && mkcert -install"
  exit 1
fi

# Ensure the mkcert CA is trusted by the system
mkcert -install

mkdir -p "$CERT_DIR"

echo "Generating locally-trusted certificate for dev.sand..."
mkcert \
  -cert-file "$CERT_DIR/cert.pem" \
  -key-file  "$CERT_DIR/key.pem" \
  dev.sand "*.dev.sand" localhost 127.0.0.1 ::1

echo ""
echo "Certificate written to: $CERT_DIR"
echo "It will be used automatically by deploy:local."
