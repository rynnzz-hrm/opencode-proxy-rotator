#!/usr/bin/env bash
# opencode-proxy-rotator — configure proxy chain for OpenCode on this box.
#
# Scope: this script configures ONLY the proxy + opencode. It does NOT touch
# 9router, pi, or any other service. Idempotent: safe to run repeatedly.
#
# Chain:
#   opencode / anything using the proxy
#     -> oc-free-proxy  :6446   (OpenAI-compatible, forwards to opencode.ai)
#     -> warp-svc       :40000  (Cloudflare WARP SOCKS5)
#     -> internet (Cloudflare egress IP)
#
# The old wgcf pool (wg-pool-rotate) is dead: 29/30 keys rejected by
# Cloudflare. This setup keeps it disabled forever.

set -euo pipefail

SOCKS_PORT="40000"
PROXY_PORT="6446"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

# --- 1. clear any orphan node socks5 squatting on :40000 ----------------
# The old wg-pool-rotate spawned `node socks5-proxy.mjs`. Orphans hold :40000
# and block warp-svc from binding -> egress dies. Kill them; warp-svc self-heals.
kill_squatter() {
    local pid
    pid=$(ss -tlnp 2>/dev/null | grep ":$SOCKS_PORT" \
          | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [ -n "$pid" ] && ps -p "$pid" -o comm= 2>/dev/null | grep -q node; then
        log "killing orphan node on :${SOCKS_PORT} (pid $pid)"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
}

# --- 2. warp-svc owns the WARP SOCKS5 on :40000 -------------------------
start_warp() {
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    systemctl start warp-svc >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        if ss -tln 2>/dev/null | grep -q ":$SOCKS_PORT"; then
            log "warp-svc listening on :${SOCKS_PORT}"
            return 0
        fi
        sleep 1
    done
    die "warp-svc did not bind :${SOCKS_PORT} in 20s"
}

# --- 3. oc-free-proxy :6446 (OpenAI-compatible surface for opencode) -----
ensure_oc_proxy_js() {
    [ -f /usr/local/bin/oc-free-proxy.js ] \
        || die "missing /usr/local/bin/oc-free-proxy.js"
}

deploy_oc_unit() {
    if systemctl is-active --quiet oc-free-proxy; then
        log "oc-free-proxy already active"
        return 0
    fi
    local unit="/etc/systemd/system/oc-free-proxy.service"
    local run_user="${OC_PROXY_USER:-rynn}"   # override with OC_PROXY_USER=... if needed
    cat > "$unit" <<EOF
[Unit]
Description=OC Free Proxy (OpenCode -> WARP)
After=network.target

[Service]
Type=simple
User=${run_user}
Environment=ALL_PROXY=socks5://127.0.0.1:40000
Environment=HOME=/home/${run_user}
ExecStart=/usr/bin/node /usr/local/bin/oc-free-proxy.js
Restart=always
RestartSec=5
WorkingDirectory=/home/${run_user}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now oc-free-proxy >/dev/null 2>&1 || true
    systemctl start oc-free-proxy >/dev/null 2>&1 || true
    log "oc-free-proxy unit written + started on :${PROXY_PORT}"
}

# --- 4. rotation + retired wg pool ---------------------------------------
configure_rotation() {
    if systemctl is-active --quiet warp-rotate.timer; then
        log "warp-rotate.timer active (IP rotation ~every 20 min)"
    else
        log "warp-rotate.timer missing — rotation unavailable (optional)"
    fi
    # never resurrect the broken wg pool
    systemctl disable --now wg-pool-rotate.timer >/dev/null 2>&1 || true
    systemctl disable wg-pool-rotate.service >/dev/null 2>&1 || true
}

# --- 5. opencode sees the proxy -------------------------------------------
# Point opencode's OpenAI-compatible base URL at oc-free-proxy. Written to
# /etc/profile.d so every login shell gets it. Proxy + opencode only.
write_opencode_env() {
    local envfile="/etc/profile.d/opencode-proxy.sh"
    if [ -f "$envfile" ] && grep -q "OPENCODE_BASE_URL" "$envfile"; then
        log "opencode proxy env already present ($envfile)"
        return 0
    fi
    cat > "$envfile" <<'EOF'
# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)
export ALL_PROXY=socks5://127.0.0.1:40000
export OPENCODE_BASE_URL=http://127.0.0.1:6446/v1
EOF
    log "wrote opencode proxy env to $envfile"
}

print_models() {
    log "models via proxy (should list free models):"
    curl -s --max-time 8 "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null \
        | grep -oP '"id":"\K[^"]+' | sed 's/^/  - /' || true
}

# --- main -----------------------------------------------------------------
kill_squatter
start_warp
kill_squatter   # race guard: warp may have lost the port to a respawned node
ensure_oc_proxy_js
deploy_oc_unit
configure_rotation
write_opencode_env
sleep 2
print_models

log "done. chain: opencode -> oc-free-proxy:${PROXY_PORT} -> WARP:${SOCKS_PORT}"
echo -n "egress: "
curl -s --max-time 8 https://api.ipify.org; echo
echo "   (expect a 104.28.x Cloudflare IP)"
