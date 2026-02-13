#!/usr/bin/env bash
set -euo pipefail

# Generate locally-trusted certificate for sandcastle.local using mkcert
# This certificate will be automatically trusted by your browser

CERT_DIR="/tmp/sandcastle-traefik-certs"

if ! command -v mkcert &> /dev/null; then
  echo "Error: mkcert is not installed"
  echo "Install with: brew install mkcert"
  echo "Then run: mkcert -install"
  exit 1
fi

# Ensure mkcert CA is installed in system keychain
if ! mkcert -CAROOT &> /dev/null; then
  echo "Installing mkcert CA in system keychain..."
  mkcert -install
fi

echo "Generating locally-trusted certificate for sandcastle.local..."
mkdir -p "$CERT_DIR"

# Generate certificate for sandcastle.local
cd "$CERT_DIR"
mkcert \
  -cert-file cert.pem \
  -key-file key.pem \
  sandcastle.local \
  "*.sandcastle.local" \
  localhost \
  127.0.0.1 \
  ::1

echo ""
echo "✓ Certificate generated at: $CERT_DIR"
echo "  - cert.pem (certificate)"
echo "  - key.pem (private key)"
echo ""
echo "The certificate is now trusted by your system."
echo "Restart Traefik with: mise run deploy:local"
