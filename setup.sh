#!/usr/bin/env bash
# opencode-proxy-rotator — orchestrator. Runs the module scripts in order.
#
# Usage: ./setup.sh            # root or non-root; detects mode automatically
#
# Chain:
#   opencode / anything using the proxy
#     -> oc-free-proxy  :6446   (OpenAI-compatible, forwards to opencode.ai)
#     -> [WARP]         :40000  (optional Cloudflare WARP SOCKS5, if installed)
#     -> internet
#
# Modules (all in modules/):
#   01-warp.sh     kill orphan node squatters, bring up WARP (registration, drop-in, bind)
#   02-proxy.sh    install oc-free-proxy.js + npm deps + systemd unit
#   03-rotation.sh rotation timer + daily heal-guard + disable dead wg pool
#   04-sync.sh     supervised free-model sync (probe before trust) + daily timer
#   05-env.sh      opencode env (global ALL_PROXY + OPENCODE_BASE_URL)
#   06-verify.sh   final health, models list, egress check (hard fail on breakage)
#   07-healthcheck.sh 1-min healthcheck + auto-heal (restart proxy / rotate WARP on deep FAIL)
#
# Every module is standalone-testable: `bash modules/01-warp.sh` runs that
# module alone. The orchestrator just sequences them.
#
# Idempotent + self-healing. NEVER touches 9router, pi, or anything else.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODULES="${MODULES_DIR:-$HERE/modules}"

# single source of shared helpers
. "$MODULES/common.sh"

# ensure a systemd user unit scope can run without lingering session
if ! is_root; then
    local_uid="$(id -u)"
    export XDG_RUNTIME_DIR="/run/user/$local_uid"
fi

log "mode: $(is_root && echo SYSTEM-Root || echo USER-nonroot)"

# spacing/platform: skip warp-specific module when warp-cli absent gracefully
run() {
    local m="$1"
    log "== module $m =="
    # shellcheck disable=SC1090
    . "$MODULES/$m"
    module_main
}

run 01-warp.sh
# ensure no squatter grabbed :40000 while WARP was starting
kill_squatters
run 02-proxy.sh
run 03-rotation.sh
run 04-sync.sh
run 05-env.sh
run 06-verify.sh
run 07-healthcheck.sh

log "== setup complete =="