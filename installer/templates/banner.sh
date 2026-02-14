#!/bin/bash
# Sandcastle login banner

# Only show on interactive shells
[[ $- == *i* ]] || return 0

# Skip if already shown in this session
[[ -n "${SANDCASTLE_BANNER_SHOWN:-}" ]] && return 0
export SANDCASTLE_BANNER_SHOWN=1

# Get version from image build metadata
if [ -f /etc/sandcastle-version ]; then
  VERSION=$(cat /etc/sandcastle-version)
else
  VERSION="unknown"
fi

cat << 'EOF'

  ███████╗ █████╗ ███╗   ██╗██████╗  ██████╗ █████╗ ███████╗████████╗██╗     ███████╗
  ██╔════╝██╔══██╗████╗  ██║██╔══██╗██╔════╝██╔══██╗██╔════╝╚══██╔══╝██║     ██╔════╝
  ███████╗███████║██╔██╗ ██║██║  ██║██║     ███████║███████╗   ██║   ██║     █████╗
  ╚════██║██╔══██║██║╚██╗██║██║  ██║██║     ██╔══██║╚════██║   ██║   ██║     ██╔══╝
  ███████║██║  ██║██║ ╚████║██████╔╝╚██████╗██║  ██║███████║   ██║   ███████╗███████╗
  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚══════╝

EOF

echo "  Version: ${VERSION}"
echo "  Docs:    https://github.com/thieso2/Sandcastle"
echo ""
