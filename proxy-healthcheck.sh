#!/usr/bin/env bash
# proxy-healthcheck.sh — passive 1-min checks + 30-min deep chat check + auto-heal.
# AUDIT FIXES 2026-08-16:
#  - cooldown checked BEFORE any chat (was AFTER — inert, burned quota while
#    suppressing heals; throttle 1800s > cooldown 1200s meant it never bound).
#  - 429 (quota) distinguished from 5xx/000 (broken): a quota 429 is OBSERVED,
#    not healed — healing a quota-latched IP just thrashes.
#  - circuit breaker: max 3 heals/hour, then ALERT and stop.
#  - post-heal verification: confirm chat works after rotate before exiting.
#  - state moved out of /tmp (wiped on reboot) into $HOME/var.
#  - egress-not-CF now triggers the heal ladder (was: detected, never healed).
#  - warp-heal (tunnel repair) wired into the ladder for non-CF egress states.
set -uo pipefail
LOG="${HOME:-/root}/logs/proxy-healthcheck-failures.txt"
STATE_DIR="${HOME:-/root}/var/proxy-healthcheck"
mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
COOLDOWN="$STATE_DIR/heal-cooldown"
HEAL_COUNT="$STATE_DIR/heal-count"
DEEP_MARKER="$STATE_DIR/deep-check"
DEEP_BODY="$STATE_DIR/deep-body.json"

# root/system unit, or user units: pick the right systemctl wrapper
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SC="sudo -n systemctl"; else SC="systemctl --user"; fi

now() { date +%s; }
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# passive health — proxy process alive? (unambiguous, heal immediately)
if [ "$(curl -s --max-time 6 http://127.0.0.1:6446/health 2>/dev/null | grep -c '"status":"ok"')" != "1" ]; then
    log "FAIL: /health (proxy down?)"
    if $SC restart oc-free-proxy >/dev/null 2>&1; then
        log "HEAL: restarted oc-free-proxy after /health FAIL"
    else
        log "HEAL-FAIL: could not restart oc-free-proxy (SC=$SC)"
    fi
    exit 1
fi

# deep check at most every 30 min (marker mtime) — BEFORE any chat
if [ -f "$DEEP_MARKER" ] && [ $(( $(now) - $(stat -c %Y "$DEEP_MARKER") )) -lt 1800 ]; then exit 0; fi

# heal cooldown: recently healed → observe, don't burn more quota
if [ -f "$COOLDOWN" ] && [ $(( $(now) - $(stat -c %Y "$COOLDOWN") )) -lt 1200 ]; then exit 0; fi

touch "$DEEP_MARKER"

# egress check via the WARP socks (ipinfo is Google-hosted → real tunnel egress)
eg=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:40000 https://ipinfo.io/ip 2>/dev/null || echo "")
case "$eg" in
  104.28.*|162.159.*|172.64.*) eg_ok=1 ;;
  *) eg_ok=0 ;;
esac
if [ "$eg_ok" != "1" ]; then
    log "FAIL: egress not Cloudflare ($eg) — WARP tunnel down or direct-fallback"
fi

# deep chat — only when the egress gate passed (CF egress present)
if [ "$eg_ok" = "1" ]; then
    code=$(curl -s --max-time 40 -o "$DEEP_BODY" -w '%{http_code}' -X POST http://127.0.0.1:6446/v1/chat/completions \
      -H "Content-Type: application/json" -d '{"model":"deepseek-v4-flash-free","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' 2>/dev/null || echo 000)
    if [ "$code" = "200" ] && grep -q '"choices"' "$DEEP_BODY" 2>/dev/null; then
        exit 0
    fi
    if [ "$code" = "429" ]; then
        # quota-exhausted on this IP — NOT a broken proxy. Observe, do NOT heal-thrash.
        log "OBSERVE: deep chat 429 (per-IP quota on egress=$eg) — waiting for rotation"
        exit 0
    fi
    log "FAIL: deep-check chat through :6446 broken (code=$code egress=$eg)"
fi

# --- auto-heal ladder ---
# circuit breaker: max 3 heals per hour
hcount=0
[ -f "$HEAL_COUNT" ] && hcount=$(cat "$HEAL_COUNT" 2>/dev/null || echo 0)
if [ -f "$HEAL_COUNT" ] && [ $(( $(now) - $(stat -c %Y "$HEAL_COUNT") )) -gt 3600 ]; then hcount=0; fi
if [ "$hcount" -ge 3 ]; then
    log "ALERT: 3 heals this hour — circuit breaker OPEN, waiting for rotation/operator (egress=$eg)"
    exit 1
fi
echo $((hcount + 1)) > "$HEAL_COUNT"
touch "$COOLDOWN"

log "HEAL: restart oc-free-proxy (egress=$eg)"
$SC restart oc-free-proxy >/dev/null 2>&1 || log "HEAL-FAIL: restart failed (SC=$SC)"
sleep 5
eg2=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:40000 https://ipinfo.io/ip 2>/dev/null || echo "")
case "$eg2" in
  104.28.*|162.159.*|172.64.*) eg2_ok=1 ;;
  *) eg2_ok=0 ;;
esac
if [ "$eg2_ok" != "1" ] || [ "$eg2" = "$eg" ]; then
    log "HEAL: rotate WARP (egress unchanged $eg)"
    $SC start warp-rotate.service >/dev/null 2>&1 || log "HEAL-FAIL: rotate start failed"
    sleep 20
fi
if [ "$eg2_ok" != "1" ]; then
    # tunnel still not on Cloudflare — run the actual tunnel repair
    if [ -x /usr/local/bin/warp-heal ]; then
        log "HEAL: tunnel repair (warp-heal)"
        /usr/local/bin/warp-heal >> "$LOG" 2>&1 || log "HEAL-FAIL: warp-heal exit $?"
        sleep 10
    fi
fi

# post-heal verification
code2=$(curl -s --max-time 40 -o "$DEEP_BODY" -w '%{http_code}' -X POST http://127.0.0.1:6446/v1/chat/completions \
  -H "Content-Type: application/json" -d '{"model":"deepseek-v4-flash-free","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' 2>/dev/null || echo 000)
if [ "$code2" = "200" ] && grep -q '"choices"' "$DEEP_BODY" 2>/dev/null; then
    log "HEAL: verified — chat 200 after heal"
    exit 0
fi
log "FAIL: post-heal verification chat $code2 — still broken"
exit 1
