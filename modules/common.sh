#!/usr/bin/env bash
# common.sh — shared helpers + path resolution for the opencode-proxy modules.
# Source this first: `. "$(dirname "$0")/common.sh"` (or from setup.sh).
#
# Behavior: root -> system paths; non-root -> user paths. Everything else reads
# $SYSTEMD_DIR, $BIN_DIR, and uses systemctl_cmd() so modules are path-agnostic.

set -euo pipefail

SOCKS_PORT="${SOCKS_PORT:-40000}"
PROXY_PORT="${PROXY_PORT:-6446}"

is_root() { [ "$(id -u)" -eq 0 ]; }

if is_root; then
    SYSTEMD_DIR="/etc/systemd/system"
    BIN_DIR="/usr/local/bin"
    systemctl_cmd() { systemctl "$@"; }
else
    SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    BIN_DIR="${HOME}/.local/bin"
    mkdir -p "$SYSTEMD_DIR" "$BIN_DIR"
    systemctl_cmd() { systemctl --user "$@"; }
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }