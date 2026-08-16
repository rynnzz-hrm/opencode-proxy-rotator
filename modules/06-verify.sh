#!/usr/bin/env bash
# 06-verify.sh — final health, models list, egress check. Fails hard on breakage.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

verify_all() {
    sleep 2
    echo "=== models via proxy ==="
    curl -s --max-time 8 "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null | grep -oP '"id":"\K[^"]+' | sed 's/^/  - /' || true

    echo -n "egress via proxy: "
    local eg
    eg=$(curl -s --max-time 8 -x socks5h://127.0.0.1:${SOCKS_PORT} https://ipinfo.io/ip 2>/dev/null || echo "")
    echo "$eg"
    local ph="no"
    if curl -s --max-time 6 "http://127.0.0.1:${PROXY_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'; then ph="yes"; fi

    if [ "$ph" = "yes" ] && [ -n "$eg" ]; then
        log "proxy OK (health=yes), egress=$eg"
        command -v warp-cli >/dev/null 2>&1 && case "$eg" in
            104.28.*|162.159.*|172.64.*) log "ALL GREEN: WARP egress $eg" ;;
            *) log "(non-Cloudflare egress — direct is fine, WARP tunnel may be down)" ;;
        esac || true
    else
        die "CHECK FAILED: proxy_healthy=$ph egress='$eg'"
    fi
}

module_main() {
    verify_all
}

if [ "$(basename "$0")" = "06-verify.sh" ]; then
    module_main
fi
