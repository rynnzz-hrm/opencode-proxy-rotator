#!/usr/bin/env bash
# opencode-proxy-rotator — configure the proxy chain for OpenCode on this box.
#
# Scope: proxy + opencode ONLY. Does not touch 9router, pi, anything else.
# Idempotent + self-healing: never deletes a working setup; repairs partial
# ones (wrong-but-active proxy, dropped registration, missing rotation timer).
#
# Chain:
#   opencode / anything using the proxy
#     -> oc-free-proxy  :6446   (OpenAI-compatible, forwards to opencode.ai)
#     -> warp-svc       :40000  (Cloudflare WARP SOCKS5)
#     -> internet (Cloudflare egress IP)

set -euo pipefail

SOCKS_PORT="40000"
PROXY_PORT="6446"
RUN_USER="rynn"   # hardcoded: this box's proxy runs as rynn. No env override (unit-injection risk).

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

# ---------------------------------------------------------------------------
# 1. clear orphan node socks5 squatters on :40000
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. warp-svc: bind the port AND ensure a real registration exists
# ---------------------------------------------------------------------------
start_warp() {
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    systemctl start warp-svc >/dev/null 2>&1 || true

    local bound=""
    for _ in $(seq 1 20); do
        if ss -tln 2>/dev/null | grep -q ":$SOCKS_PORT"; then
            bound="yes"
            break
        fi
        sleep 1
    done
    [ -n "$bound" ] || die "warp-svc did not bind :${SOCKS_PORT} in 20s"

    # registration present? repair a dropped one (rotation delete/new can leave none)
    if command -v warp-cli >/dev/null 2>&1; then
        if warp-cli --accept-tos registration show >/dev/null 2>&1; then
            log "warp-svc on :${SOCKS_PORT} with registration present"
        else
            log "registration missing — registering + connecting"
            warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
            warp-cli --accept-tos registration new >/dev/null 2>&1 || true
            warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
            warp-cli --accept-tos connect >/dev/null 2>&1 || true
        fi
    else
        log "warp-cli not found — skipping registration check"
    fi
}

# ---------------------------------------------------------------------------
# 3. oc-free-proxy unit: content-checked; repairs wrong-but-active
# ---------------------------------------------------------------------------
ensure_oc_proxy_js() {
    [ -f /usr/local/bin/oc-free-proxy.js ] \
        || die "missing /usr/local/bin/oc-free-proxy.js"
}

deploy_oc_unit() {
    local unit="/etc/systemd/system/oc-free-proxy.service"
    local want="Environment=ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}"

    if systemctl is-active --quiet oc-free-proxy \
       && [ -f "$unit" ] && grep -qF "$want" "$unit" 2>/dev/null; then
        log "oc-free-proxy active with correct config"
        return 0
    fi

    cat > "$unit" <<EOF
[Unit]
Description=OC Free Proxy (OpenCode -> WARP)
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Environment=ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}
Environment=HOME=/home/${RUN_USER}
ExecStart=/usr/bin/node /usr/local/bin/oc-free-proxy.js
Restart=always
RestartSec=5
WorkingDirectory=/home/${RUN_USER}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now oc-free-proxy >/dev/null 2>&1 || true
    systemctl restart oc-free-proxy >/dev/null 2>&1 || true
    log "wrote + restarted oc-free-proxy unit (port :${PROXY_PORT})"
}

# ---------------------------------------------------------------------------
# 4. rotation timer (deploy if missing) + keep dead wg pool off
# ---------------------------------------------------------------------------
deploy_rotation() {
    local rot="/usr/local/bin/warp-rotate"
    if [ ! -f "$rot" ]; then
        cat > "$rot" <<'ROT'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log "=== WARP IP rotation ==="
if ss -tn state established 2>/dev/null | grep ":6446" | awk '
    { if ($1+0 > 0 || $2+0 > 0) { f=1 } }
    END { exit (f ? 0 : 1) }'; then
    log "SKIP: live traffic on :6446"
    exit 0
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

    local svc="/etc/systemd/system/warp-rotate.service"
    [ -f "$svc" ] || cat > "$svc" <<'SVC'
[Unit]
Description=WARP IP Rotation

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-rotate
SVC

    local tmr="/etc/systemd/system/warp-rotate.timer"
    [ -f "$tmr" ] || cat > "$tmr" <<'TMR'
[Unit]
Description=Rotate WARP IP every 20 min

[Timer]
OnBootSec=5min
OnUnitActiveSec=20min
RandomizedDelaySec=3min
Persistent=true

[Install]
WantedBy=timers.target
TMR

    systemctl daemon-reload
    systemctl enable --now warp-rotate.timer >/dev/null 2>&1 || true
    if systemctl is-active --quiet warp-rotate.timer; then
        log "warp-rotate.timer active"
    else
        log "warp-rotate.timer not running (minor — use systemctl start warp-rotate.timer)"
    fi

    systemctl disable --now wg-pool-rotate.timer >/dev/null 2>&1 || true
    systemctl disable wg-pool-rotate.service >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 5. opencode env (content-checked)
# ---------------------------------------------------------------------------
write_opencode_env() {
    local envfile="/etc/profile.d/opencode-proxy.sh"
    local want="OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    if [ -f "$envfile" ] && grep -qF "$want" "$envfile"; then
        log "opencode proxy env already correct"
        return 0
    fi
    cat > "$envfile" <<EOF
# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)
export ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}
export OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1
EOF
    log "wrote opencode proxy env to $envfile"
}

proxy_healthy() {
    curl -s --max-time 6 "http://127.0.0.1:${PROXY_PORT}/health" 2>/dev/null \
        | grep -q '"status":"ok"'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    kill_squatters
    start_warp
    kill_squatters          # race guard: warp may have lost the port again
    ensure_oc_proxy_js
    deploy_oc_unit
    deploy_rotation
    write_opencode_env
    sleep 2

    echo "=== models via proxy ==="
    curl -s --max-time 8 "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null \
        | grep -oP '"id":"\K[^"]+' | sed 's/^/  - /' || true

    echo -n "egress via WARP: "
    local eg
    eg=$(curl -s --max-time 8 -x socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org 2>/dev/null || echo "")
    local ph="no"
    proxy_healthy && ph="yes"

    if [ "$ph" = "yes" ] && [ -n "$eg" ] && [[ "$eg" == 104.28.* ]]; then
        log "ALL GREEN: proxy ok, WARP egress = $eg"
    else
        die "CHECK FAILED: proxy_healthy=$ph egress='$eg' — WARP tunnel not healthy"
    fi
}

main "$@"