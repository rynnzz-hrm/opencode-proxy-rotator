#!/usr/bin/env bash
# 02-proxy.sh — install oc-free-proxy.js (copied FROM REPO — no heredoc) + unit + npm deps.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

ensure_oc_proxy_js() {
    local target="${BIN_DIR}/oc-free-proxy.js"
    # canonical copy lives at repo root; modules/ is one level down
    local src="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/oc-free-proxy.js"
    install -m 0755 "$src" "$target"
    log "installed oc-free-proxy.js -> $target (from repo root)"

    local pdir="${HOME}/.opencode-proxy"
    mkdir -p "$pdir"
    [ -f "$pdir/package.json" ] || printf '{"name":"opencode-proxy","private":true,"version":"1.0.0"}\n' > "$pdir/package.json"
    # socks-proxy-agent + express-rate-limit are REQUIRED by the fixed proxy
    if [ ! -d "$pdir/node_modules/express-rate-limit" ]; then
        log "npm install deps in $pdir (express, http-proxy-middleware, socks-proxy-agent, express-rate-limit)"
        (cd "$pdir" && npm install --no-fund --no-audit express http-proxy-middleware socks-proxy-agent express-rate-limit >/dev/null 2>&1) \
            || log "WARN: npm install failed — proxy will only work if deps are present"
    fi
    export NODE_PATH="$pdir/node_modules"
}

deploy_oc_unit() {
    local unit="${SYSTEMD_DIR}/oc-free-proxy.service"
    local unit_name="oc-free-proxy.service"

    # sentinel: the js must contain the current feature markers — socks-proxy-agent
    # (present since round 1) AND the round-3 env var. Checking only the socks
    # marker would skip rewriting the unit on an already-installed box, silently
    # missing OC_ALLOW_DIRECT_FALLBACK (round-4 fix). The USAGE_ALERT_TOKENS line
    # must match VALUE too, not just presence — a stale 5M default would survive
    # forever otherwise (round-6 fix: sentinel now compares the current default).
    local alert_default="${USAGE_ALERT_TOKENS:-1000000}"
    systemctl_cmd is-active --quiet "$unit_name" 2>/dev/null \
        && [ -f "$unit" ] \
        && grep -qF "socks-proxy-agent" "${BIN_DIR}/oc-free-proxy.js" 2>/dev/null \
        && grep -qF "OC_ALLOW_DIRECT_FALLBACK" "${BIN_DIR}/oc-free-proxy.js" 2>/dev/null \
        && grep -qF "OC_ALLOW_DIRECT_FALLBACK" "$unit" 2>/dev/null \
        && grep -qF "USAGE_ALERT_TOKENS=${alert_default}" "$unit" 2>/dev/null && {
        log "oc-free-proxy active with correct config"
        return 0
    }

    cat > "$unit" <<UNITEOF
[Unit]
Description=OC Free Proxy (OpenCode -> WARP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${HOME}
Environment=NODE_PATH=${HOME}/.opencode-proxy/node_modules
Environment=USAGE_ALERT_TOKENS=${USAGE_ALERT_TOKENS:-1000000}
Environment=OC_ALLOW_DIRECT_FALLBACK=${OC_ALLOW_DIRECT_FALLBACK:-0}
ExecStart=/usr/bin/node ${BIN_DIR}/oc-free-proxy.js
Restart=always
RestartSec=5
WorkingDirectory=${HOME}/.opencode-proxy

[Install]
WantedBy=default.target
UNITEOF
    systemctl_cmd daemon-reload
    systemctl_cmd enable --now "$unit_name" >/dev/null 2>&1 || true
    systemctl_cmd restart "$unit_name" >/dev/null 2>&1 || true
    log "wrote + started oc-free-proxy unit (port :${PROXY_PORT})"
}

proxy_healthy() {
    curl -s --max-time 6 "http://127.0.0.1:${PROXY_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'
}

module_main() {
    ensure_oc_proxy_js
    deploy_oc_unit
    sleep 2
    proxy_healthy && log "proxy healthy" || log "proxy NOT healthy yet"
}

if [ "$(basename "$0")" = "02-proxy.sh" ]; then
    module_main
fi
