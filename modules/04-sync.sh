#!/usr/bin/env bash
# 04-sync.sh — supervised free-model sync script + daily timer.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

deploy_sync() {
    local sync="${BIN_DIR}/sync-models.sh"
    if [ ! -f "$sync" ]; then
        cat > "$sync" <<'SYNCEOF'
#!/usr/bin/env bash
# supervised free-model sync — see opencode-proxy-rotator repo.
set -euo pipefail
PROXY_BIN="$(dirname "$(readlink -f "$0")")/oc-free-proxy.js"
MODELS_FILE="$(dirname "$PROXY_BIN")/free-models.json"
UPSTREAM_LIST="https://opencode.ai/zen/v1/models"
UPSTREAM_CHAT="https://opencode.ai/zen/v1/chat/completions"
UPSTREAM_AUTH="${OC_UPSTREAM_AUTH:-}"
PROBE_TIMEOUT="30"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
restart_proxy() {
    if [ "$(id -u)" -eq 0 ]; then systemctl restart oc-free-proxy >/dev/null 2>&1 || true
    else systemctl --user restart oc-free-proxy >/dev/null 2>&1 || true; fi
}
probe_model() {
    local model="$1" auth_hdr=() body resp
    [ -n "$UPSTREAM_AUTH" ] && auth_hdr=(-H "Authorization: Bearer ${UPSTREAM_AUTH}")
    body="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"
    resp=$(curl -sk --max-time "$PROBE_TIMEOUT" -o /tmp/probe-body.json -w '%{http_code}' \
        -X POST "$UPSTREAM_CHAT" -H "Content-Type: application/json" "${auth_hdr[@]}" -d "$body" 2>/dev/null || echo "000")
    [ "$resp" = "200" ] && grep -q '"choices"' /tmp/probe-body.json 2>/dev/null
}
fetch_free_models() {
    curl -sk --max-time 20 "$UPSTREAM_LIST" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d.get('data', []):
        if m.get('id','').endswith('-free'): print(m['id'])
except Exception: pass"
}
log "=== supervised free-model sync ==="
mapfile -t CANDIDATES < <(fetch_free_models)
[ "${#CANDIDATES[@]}" -eq 0 ] && { log "ERROR: no free models upstream — keeping existing allowlist"; exit 1; }
log "candidates (${#CANDIDATES[@]}): ${CANDIDATES[*]}"
GOOD=()
for m in "${CANDIDATES[@]}"; do
    if probe_model "$m"; then log "  OK   $m"; GOOD+=("$m"); else log "  SKIP $m (probe failed)"; fi
done
rm -f /tmp/probe-body.json
[ "${#GOOD[@]}" -eq 0 ] && { log "ERROR: no model passed probing — keeping existing allowlist"; exit 1; }
set +e
python3 - "$MODELS_FILE" "${GOOD[@]}" <<'PY'
import json, sys
path = sys.argv[1]; models = sys.argv[2:]
try: old = json.load(open(path))
except Exception: old = None
if old == models: sys.exit(0)
json.dump(models, open(path, "w"), indent=2)
sys.exit(1)
PY
changed=$?
set -e
if [ "$changed" -eq 0 ]; then log "allowlist unchanged (${#GOOD[@]} models) — no restart"
else log "wrote ${#GOOD[@]} working models to $MODELS_FILE: ${GOOD[*]}"; restart_proxy; log "restarted oc-free-proxy"; fi
log "=== sync complete ==="
SYNCEOF
        chmod +x "$sync"
        log "wrote model sync $sync"
    fi

    local ss="${SYSTEMD_DIR}/sync-models.service"
    [ -f "$ss" ] || cat > "$ss" <<'SSEOF'
[Unit]
Description=Sync opencode free models (supervised probe)
[Service]
Type=oneshot
ExecStart=/var/tmp/sync-models.sh
SSEOF
    sed -i "s|ExecStart=.*|ExecStart=${BIN_DIR}/sync-models.sh|" "$ss"

    local st="${SYSTEMD_DIR}/sync-models.timer"
    [ -f "$st" ] || cat > "$st" <<'STEOF'
[Unit]
Description=Sync opencode free models daily
[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
STEOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now sync-models.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet sync-models.timer && log "sync-models.timer active (daily model sync)" || log "sync-models.timer not running"
}

module_main() {
    deploy_sync
}

if [ "$(basename "$0")" = "04-sync.sh" ]; then
    module_main
fi