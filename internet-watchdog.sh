#!/usr/bin/env bash
# internet-watchdog.sh — 3-second auto-detection + auto-rotate
# Checks:
# 1. Can we reach opencode.ai? (DNS + HTTP)
# 2. Is WARP tunnel alive? (port 40000 listening)
# 3. Is proxy healthy? (/health endpoint)
# 4. Is the egress IP valid? (Cloudflare range)
#
# Auto-actions:
# - Internet down → rotate WARP, alert
# - WARP down → restart warp-svc, alert
# - Proxy down → restart proxy, alert
# - Egress IP burned → rotate WARP
#
# 2026-09-01 Phase 3: Internet watchdog

set -uo pipefail

LOG_DIR="/var/log/oc-proxy"
mkdir -p "$LOG_DIR"
WATCHDOG_LOG="$LOG_DIR/watchdog.jsonl"

# Thresholds
UPSTREAM_TIMEOUT=5
PROXY_TIMEOUT=3
MAX_CONSECUTIVE_FAILURES=3

# State
consecutive_failures=0
last_ip=""
last_check_ok=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_jsonl() { echo "$1" >> "$WATCHDOG_LOG"; }

# Check 1: Can we reach opencode.ai?
check_upstream() {
    local resp
    resp=$(curl -s --max-time "$UPSTREAM_TIMEOUT" -o /dev/null -w '%{http_code}' \
        --socks5-hostname 127.0.0.1:40000 \
        https://opencode.ai/zen/v1/models 2>/dev/null || echo "000")
    [ "$resp" = "200" ] || [ "$resp" = "401" ] || [ "$resp" = "403" ]
}

# Check 2: Is WARP tunnel alive?
check_warp() {
    ss -tln 2>/dev/null | grep -q ":40000"
}

# Check 3: Is proxy healthy?
check_proxy() {
    local resp
    resp=$(curl -s --max-time "$PROXY_TIMEOUT" http://127.0.0.1:6446/health 2>/dev/null)
    echo "$resp" | grep -q '"status":"ok"'
}

# Check 4: Is egress IP in Cloudflare range?
check_egress_ip() {
    local ip
    ip=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:40000 https://ipinfo.io/ip 2>/dev/null)
    case "$ip" in
        104.28.*|162.159.*|172.64.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Trigger WARP rotation
rotate_warp() {
    local reason="$1"
    log "ROTATE: $reason"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"rotate\",\"reason\":\"$reason\"}"
    systemctl start warp-rotate.service 2>/dev/null || \
    systemctl --user start warp-rotate.service 2>/dev/null || true
}

# Restart proxy
restart_proxy() {
    local reason="$1"
    log "RESTART PROXY: $reason"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"restart_proxy\",\"reason\":\"$reason\"}"
    systemctl restart oc-free-proxy 2>/dev/null || \
    systemctl --user restart oc-free-proxy 2>/dev/null || true
}

# Restart WARP
restart_warp() {
    local reason="$1"
    log "RESTART WARP: $reason"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"restart_warp\",\"reason\":\"$reason\"}"
    systemctl restart warp-svc 2>/dev/null || true
}

# Main check loop
main() {
    # Check proxy first
    if ! check_proxy; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            restart_proxy "proxy_down_${consecutive_failures}_times"
            consecutive_failures=0
        fi
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"check\":\"proxy\",\"status\":\"fail\",\"consecutive\":$consecutive_failures}"
        return
    fi

    # Check WARP
    if ! check_warp; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            restart_warp "warp_down_${consecutive_failures}_times"
            consecutive_failures=0
        fi
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"check\":\"warp\",\"status\":\"fail\",\"consecutive\":$consecutive_failures}"
        return
    fi

    # Check upstream
    if ! check_upstream; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            rotate_warp "upstream_unreachable_${consecutive_failures}_times"
            consecutive_failures=0
        fi
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"check\":\"upstream\",\"status\":\"fail\",\"consecutive\":$consecutive_failures}"
        return
    fi

    # Check egress IP
    if ! check_egress_ip; then
        consecutive_failures=$((consecutive_failures + 1))
        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            rotate_warp "egress_not_cloudflare_${consecutive_failures}_times"
            consecutive_failures=0
        fi
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"check\":\"egress_ip\",\"status\":\"fail\",\"consecutive\":$consecutive_failures}"
        return
    fi

    # All checks passed
    if [ "$consecutive_failures" -gt 0 ]; then
        log "RECOVERED after $consecutive_failures failures"
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"recovered\",\"after_failures\":$consecutive_failures}"
    fi
    consecutive_failures=0
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"check\":\"all\",\"status\":\"ok\"}"
}

main
