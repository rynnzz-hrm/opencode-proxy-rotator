#!/usr/bin/env bash
# 07-healthcheck.sh — proxy healthcheck + AUTO-HEAL (the piece live was missing:
# its observer recorded FAIL windows for hours and never acted).
# 1-min timer: passive checks (/health, egress). Every 30 min: real chat
# completion through :6446. On deep FAIL: restart proxy -> rotate WARP, with a
# 20-min cooldown so a quota-looping WARP IP isn't hammered.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

deploy_healthcheck() {
    local hc="${BIN_DIR}/proxy-healthcheck.sh"
    local hc_src="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/proxy-healthcheck.sh"
    local hs="${SYSTEMD_DIR}/proxy-healthcheck.service"
    local ht="${SYSTEMD_DIR}/proxy-healthcheck.timer"
    install -m 0755 "$hc_src" "$hc"
    log "installed proxy-healthcheck.sh -> $hc (from repo root — cooldown-before-chat, 429-observe, circuit breaker)"

    # write the final ExecStart directly — no placeholder + sed fixup (2026-08-16 audit)
    cat > "$hs" <<HSEOF
[Unit]
Description=Proxy healthcheck (1-min, auto-heal)
[Service]
Type=oneshot
ExecStart=${BIN_DIR}/proxy-healthcheck.sh
HSEOF

    cat > "$ht" <<'HTEOF'
[Unit]
Description=Proxy healthcheck every 1 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true
[Install]
WantedBy=timers.target
HTEOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now proxy-healthcheck.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet proxy-healthcheck.timer && log "proxy-healthcheck.timer active (auto-heal)" || log "proxy-healthcheck.timer not running"
}

module_main() {
    deploy_healthcheck
}

if [ "$(basename "$0")" = "07-healthcheck.sh" ]; then
    module_main
fi
