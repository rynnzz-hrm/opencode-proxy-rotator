#!/usr/bin/env bash
# setup-opencode-proxy.sh — LEGACY monolith (2026-08-11): replaced by the
# modular setup.sh. Kept as a shim for back-compat; the embedded heredoc copies
# had drifted to PRE-FIX versions (no socks egress, no rate caps, no usage
# tracker, replace-not-merge sync) — never install from those again.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -x "$HERE/setup.sh" ]; then
    echo "[legacy] delegating to $HERE/setup.sh (modular install)"
    exec "$HERE/setup.sh" "$@"
fi
echo "setup.sh missing next to $0 — re-clone the repo or run modules manually" >&2
exit 1
