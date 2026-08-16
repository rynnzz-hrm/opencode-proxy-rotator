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
    local src="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/warp-rotate"
    install -m 0755 "$src" "$rot"
    log "installed warp-rotate -> $rot (from repo root — ipinfo probe + reg-ID verify + flock)"

    local svc="${SYSTEMD_DIR}/warp-rotate.service"
    # write the final ExecStart directly — no placeholder + sed fixup (2026-08-16 audit)
    [ -f "$svc" ] || cat > "$svc" <<SVCEOF
[Unit]
Description=WARP IP Rotation
[Service]
Type=oneshot
ExecStart=${BIN_DIR}/warp-rotate
SVCEOF

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
    local guard_src="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/warp-heal"
    local hs="${SYSTEMD_DIR}/warp-heal.service"
    local ht="${SYSTEMD_DIR}/warp-heal.timer"
    install -m 0755 "$guard_src" "$guard"
    log "installed warp-heal -> $guard (from repo root — ipinfo probe)"

    [ -f "$hs" ] || cat > "$hs" <<HSEOF
[Unit]
Description=WARP heal-guard (daily)
[Service]
Type=oneshot
ExecStart=${BIN_DIR}/warp-heal
HSEOF

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