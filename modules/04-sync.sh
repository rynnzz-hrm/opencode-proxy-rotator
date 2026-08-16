#!/usr/bin/env bash
# 04-sync.sh — supervised free-model sync (copied FROM REPO) + daily timer.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

deploy_sync() {
    local sync="${BIN_DIR}/sync-models.sh"
    local src="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/sync-models.sh"
    install -m 0755 "$src" "$sync"
    log "installed sync-models.sh -> $sync (from repo root — merge-only + socks probe)"

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
