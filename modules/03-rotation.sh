#!/usr/bin/env bash
# 03-rotation.sh — WARP IP rotation timer + daily heal-guard + kill wg pool.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

deploy_rotation() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli absent — no rotation set up (proxy direct egress)"
        return 0
    fi
    local rot="${BIN_DIR}/warp-rotate"
    if [ ! -f "$rot" ]; then
        cat > "$rot" <<'ROT'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log "=== WARP IP rotation ==="
if ss -tn state established 2>/dev/null | grep ":6446" | awk '{ if ($1+0>0 || $2+0>0) f=1 } END { exit(f?0:1) }'; then
  log "SKIP: live traffic on :6446"; exit 0
fi
OLD=$(curl -s --max-time 8 -x socks5h://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo ?)
warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
sleep 1
warp-cli --accept-tos registration new >/dev/null 2>&1 || true
warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true
sleep 8
NEW=$(curl -s --max-time 8 -x socks5h://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo ?)
log "egress $OLD -> $NEW"
ROT
        chmod +x "$rot"
        log "wrote rotation script $rot"
    fi

    local svc="${SYSTEMD_DIR}/warp-rotate.service"
    [ -f "$svc" ] || cat > "$svc" <<'SVCEOF'
[Unit]
Description=WARP IP Rotation
[Service]
Type=oneshot
ExecStart=/var/tmp/warp-rotate
SVCEOF
    sed -i "s|ExecStart=.*|ExecStart=${BIN_DIR}/warp-rotate|" "$svc"

    local tmr="${SYSTEMD_DIR}/warp-rotate.timer"
    [ -f "$tmr" ] || cat > "$tmr" <<'TMREOF'
[Unit]
Description=Rotate WARP IP every 20 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=20min
RandomizedDelaySec=3min
Persistent=true
[Install]
WantedBy=timers.target
TMREOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now warp-rotate.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet warp-rotate.timer && log "warp-rotate.timer active" || log "warp-rotate.timer not running"

    # never resurrect dead wg pool (system paths only matter if root)
    is_root && { systemctl disable --now wg-pool-rotate.timer >/dev/null 2>&1 || true; systemctl disable wg-pool-rotate.service >/dev/null 2>&1 || true; } || true
}

deploy_heal_guard() {
    local guard="${BIN_DIR}/warp-heal"
    local hs="${SYSTEMD_DIR}/warp-heal.service"
    local ht="${SYSTEMD_DIR}/warp-heal.timer"

    if ! command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli absent — no heal-guard"
        return 0
    fi

    cat > "$guard" <<'HEALEOF'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
  log "registration missing — re-registering"
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 5
fi
eg=$(curl -s --max-time 8 -x socks5h://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo "")
case "$eg" in
  104.28.*|162.159.*|172.64.*) log "heal-ok: egress $eg" ;;
  *) log "WARN: egress '$eg' not Cloudflare — run setup" ;;
esac
HEALEOF
    chmod +x "$guard"

    [ -f "$hs" ] || cat > "$hs" <<'HSEOF'
[Unit]
Description=WARP heal-guard (daily)
[Service]
Type=oneshot
ExecStart=/var/tmp/warp-heal
HSEOF
    sed -i "s|ExecStart=.*|ExecStart=${BIN_DIR}/warp-heal|" "$hs"

    [ -f "$ht" ] || cat > "$ht" <<'HTEOF'
[Unit]
Description=Run WARP heal-guard daily
[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
HTEOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now warp-heal.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet warp-heal.timer && log "warp-heal.timer active (daily guard)" || log "warp-heal.timer not running"
}

module_main() {
    deploy_rotation
    deploy_heal_guard
}

if [ "$(basename "$0")" = "03-rotation.sh" ]; then
    module_main
fi