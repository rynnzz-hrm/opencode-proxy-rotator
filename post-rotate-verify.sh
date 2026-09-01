#!/usr/bin/env bash
# post-rotate-verify.sh — verify WARP rotation actually changed the IP
# Runs after warp-rotate to confirm the new IP is different from the old one.
# If rotation failed, alert and attempt recovery.
#
# 2026-09-01 Phase 3: Called by triggerWarpRotation() in oc-free-proxy.js

set -euo pipefail

LOG_DIR="/var/log/oc-proxy"
mkdir -p "$LOG_DIR"
ROTATION_LOG="$LOG_DIR/rotation.jsonl"
VERIFY_LOG="$LOG_DIR/verify.jsonl"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_jsonl() { echo "$1" >> "$2"; }

# Get current IP via WARP
get_warp_ip() {
    curl -s --max-time 10 --socks5-hostname 127.0.0.1:40000 https://ipinfo.io/ip 2>/dev/null || echo "unknown"
}

# Get current registration ID
get_reg_id() {
    warp-cli --accept-tos registration show 2>/dev/null | grep -oP 'ID: \K[0-9a-f-]+' | head -1 || echo "unknown"
}

# Main verification
OLD_IP="${1:-unknown}"
OLD_REG="${2:-unknown}"
WAIT_SECONDS="${3:-30}"

log "=== Post-rotate verification ==="
log "Waiting ${WAIT_SECONDS}s for rotation to take effect..."
sleep "$WAIT_SECONDS"

NEW_IP=$(get_warp_ip)
NEW_REG=$(get_reg_id)

# Check if rotation actually happened
if [ "$OLD_REG" != "unknown" ] && [ "$NEW_REG" != "unknown" ] && [ "$OLD_REG" = "$NEW_REG" ]; then
    log "FAIL: Registration ID unchanged ($OLD_REG) — rotation did NOT execute"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"fail\",\"reason\":\"reg_unchanged\",\"old_ip\":\"$OLD_IP\",\"new_ip\":\"$NEW_IP\",\"old_reg\":\"$OLD_REG\",\"new_reg\":\"$NEW_REG\"}" "$VERIFY_LOG"
    exit 1
fi

if [ "$OLD_IP" != "unknown" ] && [ "$NEW_IP" != "unknown" ] && [ "$OLD_IP" = "$NEW_IP" ]; then
    log "WARN: IP unchanged ($OLD_IP) but registration changed — Cloudflare may have reassigned same IP"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"warn\",\"reason\":\"ip_unchanged\",\"old_ip\":\"$OLD_IP\",\"new_ip\":\"$NEW_IP\",\"old_reg\":\"$OLD_REG\",\"new_reg\":\"$NEW_REG\"}" "$VERIFY_LOG"
    # Not a failure — CF can assign same IP from same region
elif [ "$NEW_IP" = "unknown" ]; then
    log "FAIL: Could not determine new IP — WARP may be broken"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"fail\",\"reason\":\"ip_unknown\",\"old_ip\":\"$OLD_IP\",\"new_ip\":\"$NEW_IP\",\"old_reg\":\"$OLD_REG\",\"new_reg\":\"$NEW_REG\"}" "$VERIFY_LOG"
    exit 1
else
    log "OK: IP changed $OLD_IP -> $NEW_IP (reg $OLD_REG -> $NEW_REG)"
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ok\",\"reason\":\"rotation_success\",\"old_ip\":\"$OLD_IP\",\"new_ip\":\"$NEW_IP\",\"old_reg\":\"$OLD_REG\",\"new_reg\":\"$NEW_REG\"}" "$VERIFY_LOG"
fi

# Verify proxy is healthy after rotation
sleep 2
HEALTH=$(curl -s --max-time 5 http://127.0.0.1:6446/health 2>/dev/null)
if echo "$HEALTH" | grep -q '"status":"ok"'; then
    log "Proxy healthy after rotation"
else
    log "WARN: Proxy not healthy after rotation — restarting"
    systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
fi

log "=== Verification complete ==="
