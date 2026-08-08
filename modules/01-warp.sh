#!/usr/bin/env bash
# 01-warp.sh — kill orphan node squatters, then bring up WARP (optional).
# Standalone: `. <dir>/01-warp.sh` or run via setup.sh orchestrator.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

# --- kill orphan node socks5 squatters on :40000 (only if they're node) ----
kill_squatters() {
    local pid
    for pid in $(ss -tlnp 2>/dev/null | grep ":$SOCKS_PORT" | grep -oP 'pid=\K[0-9]+' || true); do
        if [ -n "$pid" ] && ps -p "$pid" -o comm= 2>/dev/null | grep -q node; then
            log "killing orphan node on :${SOCKS_PORT} (pid $pid)"
            kill "$pid" 2>/dev/null || true
            sleep 1
        fi
    done
}

# --- start/repair WARP: reg first, then port. Optional if no warp-cli. -----
start_warp() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli not installed — skipping WARP rotation (proxy uses direct egress)"
        return 0
    fi

    # boot-recovery: ensure warp-svc restarts reliably after reboot/crash and
    # is not throttled into a dead state by systemd's start-limit.
    if [ "$(id -u)" -eq 0 ]; then
        local wdrop="/etc/systemd/system/warp-svc.service.d"
        if [ ! -f "$wdrop/restart.conf" ]; then
            mkdir -p "$wdrop"
            cat > "$wdrop/restart.conf" <<'WDROP'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=10
WDROP
            systemctl daemon-reload >/dev/null 2>&1 || true
            log "warp-svc restart-policy drop-in installed"
        fi
    fi

    warp-cli --accept-tos registration show >/dev/null 2>&1 && {
        log "warp registration present"
    } || {
        log "registration missing — registering + connecting"
        warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
        warp-cli --accept-tos registration new >/dev/null 2>&1 || true
        warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
        warp-cli --accept-tos connect >/dev/null 2>&1 || true
    }

    local bound=""
    for _ in $(seq 1 20); do
        if ss -tln 2>/dev/null | grep -q ":$SOCKS_PORT"; then
            bound="yes"
            break
        fi
        sleep 1
    done
    if [ -n "$bound" ]; then
        log "WARP bound :${SOCKS_PORT}"
        return 0
    fi

    # tunnel registered but not listening — gentle reconnect before giving up.
    log "WARP not bound :${SOCKS_PORT} — trying reconnect"
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
    sleep 2
    for _ in $(seq 1 10); do
        if ss -tln 2>/dev/null | grep -q ":$SOCKS_PORT"; then
            bound="yes"
            break
        fi
        sleep 1
    done
    [ -n "$bound" ] || log "WARP still not bound after reconnect — proxying direct"
}

module_main() {
    kill_squatters
    start_warp
}

if [ "$(basename "$0")" = "01-warp.sh" ]; then
    module_main
fi