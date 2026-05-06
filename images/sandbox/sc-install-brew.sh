#!/bin/bash
# sc-install-brew — install Homebrew (Linuxbrew) into a chosen prefix.
#
# Homebrew is NOT baked into the sandbox base image because it's large
# (~1 GB installed) and most users rely on mise, apt, or npm instead.
# This helper gives users who do want it a one-command install.
#
# Prefixes:
#   $HOME/.linuxbrew (default) — persists across sandboxes via the
#                                bind-mounted home directory.
#   /opt/homebrew (--opt)      — shared across all users of this sandbox,
#                                but lives in the container FS, so it is
#                                LOST when the sandbox is destroyed.
#
# Note on bottles: Homebrew's precompiled binaries ("bottles") are built
# against the official prefix /home/linuxbrew/.linuxbrew. Using any other
# prefix (including both options above) forces builds from source, which
# is slower. That's an upstream Homebrew policy, not a Sandcastle choice.

set -euo pipefail

PREFIX="$HOME/.linuxbrew"

usage() {
    cat <<EOF
Usage: sc-install-brew [--prefix DIR | --opt] [--force]

Install Homebrew into a chosen prefix and append shell activation
to ~/.bashrc.

Options:
  --prefix DIR   Install location (default: \$HOME/.linuxbrew)
  --opt          Shortcut for --prefix /opt/homebrew
  --force        Reinstall even if the prefix already contains brew
  -h, --help     Show this help

The default (\$HOME/.linuxbrew) persists across sandbox recreations
because \$HOME is bind-mounted from the host. /opt/homebrew lives in
the sandbox filesystem and vanishes when the sandbox is destroyed.
EOF
}

FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ -n "${2:-}" ] || { echo "error: --prefix requires a directory" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --opt)
            PREFIX="/opt/homebrew"; shift ;;
        --force)
            FORCE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

if [ -x "$PREFIX/bin/brew" ] && [ "$FORCE" = "0" ]; then
    echo "Homebrew already installed at $PREFIX"
    echo "Activate with:  eval \"\$($PREFIX/bin/brew shellenv)\""
    exit 0
fi

# Create the prefix. $HOME is writable by the user; everywhere else needs sudo.
case "$PREFIX" in
    "$HOME"/*|"$HOME")
        mkdir -p "$PREFIX" ;;
    *)
        sudo install -d -o "$(id -u)" -g "$(id -g)" "$PREFIX" ;;
esac

echo "Cloning Homebrew into $PREFIX/Homebrew ..."
if [ -d "$PREFIX/Homebrew/.git" ] && [ "$FORCE" = "1" ]; then
    rm -rf "$PREFIX/Homebrew"
fi
git clone --depth=1 https://github.com/Homebrew/brew "$PREFIX/Homebrew"

mkdir -p "$PREFIX/bin"
ln -sf "../Homebrew/bin/brew" "$PREFIX/bin/brew"

# Append a guarded activation snippet to ~/.bashrc so a missing prefix
# doesn't break the shell on future sandbox starts.
SNIPPET_MARKER="# >>> sandcastle homebrew >>>"
if ! grep -qF "$SNIPPET_MARKER" "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "$SNIPPET_MARKER"
        echo "if [ -x \"$PREFIX/bin/brew\" ]; then"
        echo "    eval \"\$(\"$PREFIX/bin/brew\" shellenv)\""
        echo "fi"
        echo "# <<< sandcastle homebrew <<<"
    } >> "$HOME/.bashrc"
    echo "Added activation snippet to ~/.bashrc"
fi

cat <<EOF

Homebrew installed at $PREFIX
Activate in the current shell with:

    eval "\$($PREFIX/bin/brew shellenv)"

Or open a new shell.
EOF
