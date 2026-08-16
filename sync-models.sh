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
#
# 2026-08-09 shrink protection: probes fail when the current egress IP is
# rate-limited, and a degraded list DROPPED deepseek/mimo/nemotron → Sye got
# 400 "model not allowed" during an upstream outage. Now the sync MERGES new
# passing models into the existing allowlist — it can ADD, never REMOVE.
# Probes also go through the SAME WARP SOCKS the proxy uses (node's outbound
# path), so a probe result reflects what the proxy's upstream actually sees.

set -euo pipefail

PROXY_BIN="$(dirname "$(readlink -f "$0")")/oc-free-proxy.js"
MODELS_FILE="$(dirname "$PROXY_BIN")/free-models.json"
UPSTREAM_LIST="https://opencode.ai/zen/v1/models"
UPSTREAM_CHAT="https://opencode.ai/zen/v1/chat/completions"
UPSTREAM_AUTH="${OC_UPSTREAM_AUTH:-}"
PROBE_TIMEOUT="30"
# per-run probe body (PID-suffixed — concurrent runs can't clobber each other)
PROBE_BODY="/tmp/probe-body-$$.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- restart proxy (system or user mode) and VERIFY it actually restarted ---
# AUDIT FIX 2026-08-16: the old version swallowed failure (|| true) then
# unconditionally logged "restarted" — a failed restart served a stale allowlist
# silently. Now: verify is-active after, log ERROR + return 1 on failure.
restart_proxy() {
    local out rc
    if [ "$(id -u)" -eq 0 ]; then
        out=$(systemctl restart oc-free-proxy 2>&1); rc=$?
        if [ "$rc" -ne 0 ]; then log "ERROR: systemctl restart oc-free-proxy failed: $out"; return 1; fi
        sleep 2
        if ! systemctl is-active --quiet oc-free-proxy; then log "ERROR: oc-free-proxy not active after restart"; return 1; fi
    else
        out=$(systemctl --user restart oc-free-proxy 2>&1); rc=$?
        if [ "$rc" -ne 0 ]; then log "ERROR: systemctl --user restart oc-free-proxy failed: $out"; return 1; fi
        sleep 2
        if ! systemctl --user is-active --quiet oc-free-proxy; then log "ERROR: oc-free-proxy not active after restart"; return 1; fi
    fi
    return 0
}

# --- probe one model: 200 + a choices array = pass --------------------------
probe_model() {
    local model="$1"
    local auth_hdr=()
    [ -n "$UPSTREAM_AUTH" ] && auth_hdr=(-H "Authorization: Bearer ${UPSTREAM_AUTH}")
    local body="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"
    local resp
    # ${auth_hdr[@]+...} guards the empty-array expansion under set -u (bash <4.4)
    resp=$(curl -sk --max-time "$PROBE_TIMEOUT" --socks5-hostname 127.0.0.1:40000 -o "$PROBE_BODY" -w '%{http_code}' \
        -X POST "$UPSTREAM_CHAT" -H "Content-Type: application/json" ${auth_hdr[@]+"${auth_hdr[@]}"} \
        -d "$body" 2>/dev/null || echo "000")
    if [ "$resp" = "200" ] && grep -q '"choices":\s*\[\s*"' "$PROBE_BODY" 2>/dev/null; then
        return 0
    fi
    # non-empty choices[0] content — a 200 with "choices":[] must NOT pass
    if [ "$resp" = "200" ] && python3 -c "
import json,sys
try:
    d=json.load(open('$PROBE_BODY'))
    c=d.get('choices') or []
    sys.exit(0 if c and c[0].get('content') else 1)
except Exception:
    sys.exit(1)" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- fetch candidate free-model ids from upstream (SAME socks egress as probes) ---
# AUDIT FIX 2026-08-16: was DIRECT (no socks) — every sync burned the ISP IP's
# opencode quota (the 20h-lockout vector). Now routes through WARP like the rest;
# -f fails on HTTP errors instead of feeding error bodies to the JSON parser.
fetch_free_models() {
    curl -sk --max-time 20 --socks5-hostname 127.0.0.1:40000 -f "$UPSTREAM_LIST" 2>/dev/null \
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
rm -f "$PROBE_BODY"

if [ "${#GOOD[@]}" -eq 0 ]; then
    log "ERROR: no model passed probing — keeping existing allowlist"
    exit 1
fi

# write only if changed; exit 0 = unchanged, 1 = changed (wrote + needs restart)
# NOTE: must capture $? under set -e — a bare `python3; changed=$?` would let
# set -e kill the script on exit 1 before the restart block. (Stub-test catch.)
# AUDIT FIX 2026-08-16:
#  - compare SETS (sorted) not lists — the old list-equality rewrote + restarted
#    the proxy on every transient probe failure (order churn), compounding 429s.
#  - 3-strike eviction: add-only stays (shrink-protection on 1-2 bad days), but
#    a model that fails probing 3 CONSECUTIVE syncs is dropped (never-heal fix).
set +e
python3 - "$MODELS_FILE" "${GOOD[@]}" <<'PY'
import json, os, sys
path = sys.argv[1]
new = sys.argv[2:]
count_path = os.path.join(os.path.dirname(path), "free-models-failcount.json")
try:
    old = json.load(open(path))
    if not isinstance(old, list):
        old = []
except Exception:
    old = []
try:
    counts = json.load(open(count_path))
    if not isinstance(counts, dict):
        counts = {}
except Exception:
    counts = {}
newset = set(new)
merged = []
for m in old:
    if m in newset:
        merged.append(m)
        counts.pop(m, None)               # passed — reset strike count
    else:
        counts[m] = counts.get(m, 0) + 1  # not in passing set — strike++
        if counts[m] < 3:
            merged.append(m)              # keep until 3 consecutive failures
for m in new:
    if m not in merged:
        merged.append(m)
        counts.pop(m, None)
for k in list(counts):
    if k not in old and k not in newset:
        del counts[k]
json.dump(counts, open(count_path, "w"), indent=2)
if sorted(old) == sorted(merged):
    sys.exit(0)   # set unchanged — no restart, no write
json.dump(merged, open(path, "w"), indent=2)
sys.exit(1)       # set changed — caller restarts
PY
changed=$?
set -e

if [ "$changed" -eq 0 ]; then
    log "allowlist unchanged (${#GOOD[@]} models) — no restart"
elif [ "$changed" -eq 1 ]; then
    log "wrote ${#GOOD[@]} working models to $MODELS_FILE: ${GOOD[*]}"
    if restart_proxy; then
        log "restarted oc-free-proxy (verified)"
    else
        log "ERROR: allowlist written but restart FAILED — proxy serving stale list until next restart"
        exit 1
    fi
else
    log "ERROR: merge python exited $changed — allowlist NOT written"
    exit 1
fi
log "=== sync complete ==="