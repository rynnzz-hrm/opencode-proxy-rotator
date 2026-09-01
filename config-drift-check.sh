#!/usr/bin/env bash
# config-drift-check.sh — auto-redeploy when code is broken/modified
# Runs every 5 minutes via systemd timer.
# Checks:
# 1. Does oc-free-proxy.js have Hermes headers?
# 2. Is it syntactically valid? (node --check)
# 3. Does /health respond?
# 4. Is the file older than repo version?
#
# If broken:
# 1. Backup live file
# 2. Copy from repo
# 3. Restart proxy
# 4. Log warning to /var/log/oc-proxy/drift.jsonl
#
# 2026-09-01 Phase 3

set -euo pipefail

# Prevent concurrent runs (race condition with rotation)
LOCK="/run/config-drift-check.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: another drift check is already running"
    exit 0
fi

LOG_DIR="/var/log/oc-proxy"
mkdir -p "$LOG_DIR"
DRIFT_LOG="$LOG_DIR/drift.jsonl"

REPO_DIR="/home/rynn/opencode-proxy-rotator"
LIVE_FILE="/usr/local/bin/oc-free-proxy.js"
BACKUP_DIR="/usr/local/bin/oc-free-proxy-backups"
MAX_BACKUPS=10  # Keep last 10 backups

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_jsonl() { echo "$1" >> "$DRIFT_LOG"; }

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Cleanup old backups (keep last MAX_BACKUPS)
cleanup_backups() {
    local count
    count=$(ls -1 "$BACKUP_DIR"/oc-free-proxy.js.bak.* 2>/dev/null | wc -l)
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -1t "$BACKUP_DIR"/oc-free-proxy.js.bak.* | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
        log "Cleaned up old backups (kept $MAX_BACKUPS)"
    fi
}

# Check 1: Does the file exist?
if [ ! -f "$LIVE_FILE" ]; then
    log "FAIL: $LIVE_FILE does not exist — deploying from repo"
    cp "$REPO_DIR/oc-free-proxy.js" "$LIVE_FILE"
    chmod +x "$LIVE_FILE"
    systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"deployed\",\"reason\":\"file_missing\",\"action\":\"restored_from_repo\"}"
    exit 0
fi

# Check 2: Does it have Hermes headers?
if ! grep -q "HTTP-Referer.*hermes-agent" "$LIVE_FILE"; then
    log "FAIL: $LIVE_FILE missing Hermes headers — deploying from repo"
    cp "$LIVE_FILE" "$BACKUP_DIR/oc-free-proxy.js.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$REPO_DIR/oc-free-proxy.js" "$LIVE_FILE"
    chmod +x "$LIVE_FILE"
    systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"deployed\",\"reason\":\"missing_hermes_headers\",\"action\":\"restored_from_repo\"}"
    exit 0
fi

# Check 3: Is it syntactically valid?
if ! node --check "$LIVE_FILE" 2>/dev/null; then
    log "FAIL: $LIVE_FILE has syntax errors — deploying from repo"
    cp "$LIVE_FILE" "$BACKUP_DIR/oc-free-proxy.js.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$REPO_DIR/oc-free-proxy.js" "$LIVE_FILE"
    chmod +x "$LIVE_FILE"
    systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"deployed\",\"reason\":\"syntax_error\",\"action\":\"restored_from_repo\"}"
    exit 0
fi

# Check 4: Does /health respond?
HEALTH=$(curl -s --max-time 5 http://127.0.0.1:6446/health 2>/dev/null || echo "")
if ! echo "$HEALTH" | grep -q '"status":"ok"'; then
    log "FAIL: /health not responding — restarting proxy"
    systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
    sleep 2
    HEALTH=$(curl -s --max-time 5 http://127.0.0.1:6446/health 2>/dev/null || echo "")
    if ! echo "$HEALTH" | grep -q '"status":"ok"'; then
        log "FAIL: Proxy still not healthy after restart — deploying from repo"
        cp "$LIVE_FILE" "$BACKUP_DIR/oc-free-proxy.js.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$REPO_DIR/oc-free-proxy.js" "$LIVE_FILE"
        chmod +x "$LIVE_FILE"
        systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"deployed\",\"reason\":\"health_check_failed\",\"action\":\"restored_from_repo\"}"
    else
        log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"recovered\",\"reason\":\"health_check_failed\",\"action\":\"restart_only\"}"
    fi
    exit 0
fi

# Check 5: Are there duplicate processes? (root vs user service)
DUPLICATE_COUNT=$(ps aux | grep "oc-free-proxy.js" | grep -v grep | wc -l)
if [ "$DUPLICATE_COUNT" -gt 1 ]; then
    log "WARN: $DUPLICATE_COUNT proxy processes detected — killing user-owned ones"
    # Kill any process NOT owned by root
    ps aux | grep "oc-free-proxy.js" | grep -v grep | grep -v root | awk '{print $2}' | xargs kill 2>/dev/null || true
    log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"fixed\",\"reason\":\"duplicate_processes\",\"action\":\"killed_user_processes\"}"
fi

# Check 6: Is repo version newer than live? (compare timestamps)
# First, pull latest from GitHub to ensure repo is up to date
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR" && sudo -u rynn git pull --quiet 2>/dev/null || true
fi
if [ -f "$REPO_DIR/oc-free-proxy.js" ]; then
    LIVE_MTIME=$(stat -c %Y "$LIVE_FILE" 2>/dev/null || echo "0")
    REPO_MTIME=$(stat -c %Y "$REPO_DIR/oc-free-proxy.js" 2>/dev/null || echo "0")
    if [ "$REPO_MTIME" -gt "$LIVE_MTIME" ]; then
        # Check if content actually differs (not just timestamp)
        if ! diff -q "$LIVE_FILE" "$REPO_DIR/oc-free-proxy.js" >/dev/null 2>&1; then
            log "INFO: Repo version newer — updating live"
            cp "$LIVE_FILE" "$BACKUP_DIR/oc-free-proxy.js.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$REPO_DIR/oc-free-proxy.js" "$LIVE_FILE"
            chmod +x "$LIVE_FILE"
            systemctl restart oc-free-proxy 2>/dev/null || systemctl --user restart oc-free-proxy 2>/dev/null || true
            log_jsonl "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"updated\",\"reason\":\"repo_newer\",\"action\":\"updated_from_repo\"}"
        fi
    fi
fi

# All checks passed — cleanup old backups
cleanup_backups
log "OK: All checks passed"
