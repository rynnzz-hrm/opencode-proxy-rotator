#!/usr/bin/env bash
# sync-models.sh — supervised auto-sync of the opencode FREE model allowlist.
#
# Design B (2026-08-07): never trust the upstream model list blindly. For every
# candidate `*-free` model:
#   1. list it from the upstream /zen/v1/models endpoint
#   2. PROBE it with a real chat completion (max_tokens=1) through the same
#      egress the proxy uses
#   3. keep ONLY models that return a 200 with a valid completion
#   4. write the working list to free-models.json (next to oc-free-proxy.js)
#   5. restart oc-free-proxy if the list changed
#
# Why probe: upstream can list a model (e.g. north-mini-code-free) that 401s on
# the anonymous tier. Auto-adding it would re-advertise a broken model. Probing
# is the whole point of "supervised" sync.

set -euo pipefail

PROXY_BIN="$(dirname "$(readlink -f "$0")")/oc-free-proxy.js"
MODELS_FILE="$(dirname "$PROXY_BIN")/free-models.json"
UPSTREAM_LIST="https://opencode.ai/zen/v1/models"
UPSTREAM_CHAT="https://opencode.ai/zen/v1/chat/completions"
UPSTREAM_AUTH="${OC_UPSTREAM_AUTH:-}"
PROBE_TIMEOUT="30"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- restart proxy (system or user mode, matching how setup installed it) ---
restart_proxy() {
    if [ "$(id -u)" -eq 0 ]; then
        systemctl restart oc-free-proxy >/dev/null 2>&1 || true
    else
        systemctl --user restart oc-free-proxy >/dev/null 2>&1 || true
    fi
}

# --- probe one model: 200 + a choices array = pass --------------------------
probe_model() {
    local model="$1"
    local auth_hdr=()
    [ -n "$UPSTREAM_AUTH" ] && auth_hdr=(-H "Authorization: Bearer ${UPSTREAM_AUTH}")
    local body="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"
    local resp
    resp=$(curl -sk --max-time "$PROBE_TIMEOUT" -o /tmp/probe-body.json -w '%{http_code}' \
        -X POST "$UPSTREAM_CHAT" -H "Content-Type: application/json" "${auth_hdr[@]}" \
        -d "$body" 2>/dev/null || echo "000")
    if [ "$resp" = "200" ] && grep -q '"choices"' /tmp/probe-body.json 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- fetch candidate free-model ids from upstream ---------------------------
fetch_free_models() {
    curl -sk --max-time 20 "$UPSTREAM_LIST" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d.get('data', []):
        mid = m.get('id', '')
        if mid.endswith('-free'):
            print(mid)
except Exception:
    pass"
}

# ---------------------------------------------------------------------------
log "=== supervised free-model sync ==="

# fresh candidate list
mapfile -t CANDIDATES < <(fetch_free_models)
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    log "ERROR: no free models found upstream (network/API down?) — keeping existing allowlist"
    exit 1
fi
log "candidates (${#CANDIDATES[@]}): ${CANDIDATES[*]}"

# probe each; keep only working
GOOD=()
for m in "${CANDIDATES[@]}"; do
    if probe_model "$m"; then
        log "  OK   $m"
        GOOD+=("$m")
    else
        log "  SKIP $m (probe failed — not advertised as working)"
    fi
done
rm -f /tmp/probe-body.json

if [ "${#GOOD[@]}" -eq 0 ]; then
    log "ERROR: no model passed probing — keeping existing allowlist"
    exit 1
fi

# write only if changed; exit 0 = unchanged, 1 = changed (wrote + needs restart)
# NOTE: must capture $? under set -e — a bare `python3; changed=$?` would let
# set -e kill the script on exit 1 before the restart block. (Stub-test catch.)
set +e
python3 - "$MODELS_FILE" "${GOOD[@]}" <<'PY'
import json, sys
path = sys.argv[1]
models = sys.argv[2:]
try:
    old = json.load(open(path))
except Exception:
    old = None
if old == models:
    sys.exit(0)   # unchanged — no restart
json.dump(models, open(path, "w"), indent=2)
sys.exit(1)       # changed — caller restarts
PY
changed=$?
set -e

if [ "$changed" -eq 0 ]; then
    log "allowlist unchanged (${#GOOD[@]} models) — no restart"
else
    log "wrote ${#GOOD[@]} working models to $MODELS_FILE: ${GOOD[*]}"
    restart_proxy
    log "restarted oc-free-proxy"
fi
log "=== sync complete ==="