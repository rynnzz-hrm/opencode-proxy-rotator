#!/usr/bin/env bash
# opencode-proxy-rotator — configure the proxy chain for OpenCode, sudo-free.
#
# Scope: proxy + opencode ONLY. Does not touch 9router, pi, anything else.
# Works as a normal user (no root): uses ~/.config/systemd/user + ~/.local/bin
# + ~/.profile. If running as root, uses system paths instead.
#
# Chain:
#   opencode / anything using the proxy
#     -> oc-free-proxy  :6446   (OpenAI-compatible, forwards to opencode.ai)
#     -> [WARP]         :40000  (optional Cloudflare WARP SOCKS5, if installed)
#     -> internet
#
# The proxy itself is self-installing (writes oc-free-proxy.js + npm deps).
# WARP rotation is optional: enabled only if warp-cli is available. If not, the
# proxy still works (direct egress); rotation is skipped with a note.
# Idempotent + self-healing.

set -euo pipefail

SOCKS_PORT="40000"
PROXY_PORT="6446"

# --- path selection: system (root) vs user (non-root) -------------------
is_root() { [ "$(id -u)" -eq 0 ]; }

if is_root; then
    SYSTEMD_DIR="/etc/systemd/system"
    BIN_DIR="/usr/local/bin"
    systemctl_cmd() { systemctl "$@"; }
else
    SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    BIN_DIR="${HOME}/.local/bin"
    mkdir -p "$SYSTEMD_DIR" "$BIN_DIR"
    systemctl_cmd() { systemctl --user "$@"; }
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. kill orphan node socks5 squatters on :40000 (only if they're node)
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
# 2. WARP (optional): only if warp-cli exists. Repair reg first, then port.
# ---------------------------------------------------------------------------
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

    # tunnel registered but not listening — try a gentle reconnect before giving
    # up. warp-cli connect is idempotent and does NOT tear down a healthy tunnel.
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

# ---------------------------------------------------------------------------
# 3. oc-free-proxy.js: install from this repo if missing
# ---------------------------------------------------------------------------
ensure_oc_proxy_js() {
    local target="${BIN_DIR}/oc-free-proxy.js"
    if [ -f "$target" ]; then
        log "oc-free-proxy.js already present"
        return 0
    fi
    log "installing oc-free-proxy.js -> $target"
    cat > "$target" <<'PROXYEOF'
#!/usr/bin/env node
// oc-free-proxy — Express proxy for OpenCode API (rynn-zeyn, fixed 2026-08-01)
// Bind 127.0.0.1 (was 0.0.0.0 — unauthenticated LAN proxy). Free models anonymous.
const express = require("express");
const { createProxyMiddleware } = require("http-proxy-middleware");
const https = require("https");
const app = express();
const PORT = 6446;
const BIND_HOST = "127.0.0.1";
const TARGET = "https://opencode.ai/zen";
const UPSTREAM_AUTH = process.env.OC_UPSTREAM_AUTH || "";
process.on("unhandledRejection", (e) => console.error(`[${new Date().toISOString()}] unhandledRejection: ${e.message}`));
const FREE_MODELS = ["deepseek-v4-flash-free","ling-3.0-flash-free","mimo-v2.5-free","nemotron-3-ultra-free","laguna-s-2.1-free"];
const PAID_MODELS = ["glm-5.2","deepseek-v4-pro","kimi-k3","qwen3.6-plus","minimax-m3","gpt-5.6-sol","mimo-v2-free","hy3-free"];
function allowedModels(){ return UPSTREAM_AUTH ? [...FREE_MODELS,...PAID_MODELS] : FREE_MODELS; }
app.use(express.json({ limit: "25mb" })); // 25mb: express default 100kb broke Sye Telegram payloads
app.get("/health", (req,res)=>res.json({status:"ok"}));
app.get("/v1/models", (req,res)=>{
  const opt={ hostname:"opencode.ai", path:"/zen/v1/models", method:"GET", headers:{} };
  if (UPSTREAM_AUTH) opt.headers.Authorization = UPSTREAM_AUTH;
  const up=https.request(opt,(ur)=>{ let d=""; ur.on("data",c=>d+=c); ur.on("end",()=>{ try{ const m=JSON.parse(d); res.json({data:(m.data||[]).filter(x=>allowedModels().includes(x.id))}); }catch(e){ res.json({data:[]}); } }); });
  up.on("error",()=>res.json({data:[]})); up.end();
});
// Model gate: reject chat requests for models not in the allowlist BEFORE upstream
app.post("/v1/chat/completions", (req,res,next)=>{
  const model=req.body && req.body.model;
  if (model && !allowedModels().includes(model)) {
    return res.status(400).json({error:{type:"invalid_request_error",message:`model '${model}' is not allowed. Available: ${allowedModels().join(", ")}`}});
  }
  next();
});
app.use("/", createProxyMiddleware({ target:TARGET, changeOrigin:true, on:{
  error:(e,req,res)=>{ console.error(`[${new Date().toISOString()}] Proxy error: ${e.message}`); res.status(502).json({error:"proxy_error",message:e.message}); },
  proxyReq:(pr,req)=>{ pr.removeHeader("Authorization"); pr.removeHeader("authorization"); if (UPSTREAM_AUTH) pr.setHeader("Authorization",UPSTREAM_AUTH);
    if (req.body && Object.keys(req.body).length>0){ const b=JSON.stringify(req.body); pr.setHeader("Content-Length",Buffer.byteLength(b)); pr.write(b); pr.end(); }
  }
}}));
app.listen(PORT, BIND_HOST, ()=>console.log(`[${new Date().toISOString()}] oc-free-proxy listening on ${BIND_HOST}:${PORT}`));
PROXYEOF
    chmod +x "$target"

    # install deps (express + http-proxy-middleware) via npm into a project dir
    local pdir="${HOME}/.opencode-proxy"
    mkdir -p "$pdir"
    [ -f "$pdir/package.json" ] || printf '{"name":"opencode-proxy","private":true,"version":"1.0.0"}\n' > "$pdir/package.json"
    if [ ! -d "$pdir/node_modules/express" ] || [ ! -d "$pdir/node_modules/http-proxy-middleware" ]; then
        log "npm install deps in $pdir (may need a moment)"
        (cd "$pdir" && npm install --no-fund --no-audit express http-proxy-middleware >/dev/null 2>&1) \
            || log "WARN: npm install failed — proxy will only work if deps are present"
    fi
    # point node at the project node_modules via NODE_PATH when launching
    export NODE_PATH="$pdir/node_modules"
    echo "$pdir" > "${BIN_DIR}/.oc-proxy-dir"
}

# ---------------------------------------------------------------------------
# 4. oc-free-proxy systemd unit (content-checked, path-aware)
# ---------------------------------------------------------------------------
deploy_oc_unit() {
    local unit="${SYSTEMD_DIR}/oc-free-proxy.service"
    local want="Environment=ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}"
    local unit_name="oc-free-proxy.service"

    systemctl_cmd is-active --quiet "$unit_name" 2>/dev/null \
        && [ -f "$unit" ] && grep -qF "$want" "$unit" 2>/dev/null && {
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
Environment=ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}
Environment=HOME=${HOME}
Environment=NODE_PATH=${HOME}/.opencode-proxy/node_modules
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

# ---------------------------------------------------------------------------
# 5. rotation timer (deploy if missing, warp-cli present) + keep wg pool off
# ---------------------------------------------------------------------------
deploy_rotation() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli absent — no rotation set up (proxy direct egress)"
        return 0
    fi
    local rot="${BIN_DIR}/warp-rotate"
    if [ ! -f "$rot" ]; then
        cat > "$rot" <<'ROT'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log "=== WARP IP rotation ==="
if ss -tn state established 2>/dev/null | grep ":6446" | awk '{ if ($1+0>0 || $2+0>0) f=1 } END { exit(f?0:1) }'; then
  log "SKIP: live traffic on :6446"; exit 0
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

    local svc="${SYSTEMD_DIR}/warp-rotate.service"
    [ -f "$svc" ] || cat > "$svc" <<'SVCEOF'
[Unit]
Description=WARP IP Rotation
[Service]
Type=oneshot
ExecStart=/var/tmp/warp-rotate
SVCEOF
    # fix any stale absolute path
    sed -i "s|ExecStart=.*|ExecStart=${BIN_DIR}/warp-rotate|" "$svc"

    local tmr="${SYSTEMD_DIR}/warp-rotate.timer"
    [ -f "$tmr" ] || cat > "$tmr" <<'TMREOF'
[Unit]
Description=Rotate WARP IP every 20 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=20min
RandomizedDelaySec=3min
Persistent=true
[Install]
WantedBy=timers.target
TMREOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now warp-rotate.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet warp-rotate.timer && log "warp-rotate.timer active" || log "warp-rotate.timer not running"

    # never resurrect dead wg pool (system paths only matter if root)
    is_root && { systemctl disable --now wg-pool-rotate.timer >/dev/null 2>&1 || true; systemctl disable wg-pool-rotate.service >/dev/null 2>&1 || true; } || true
}

# ---------------------------------------------------------------------------
# 6. heal-guard (daily) — only meaningful if warp-cli present
# ---------------------------------------------------------------------------
deploy_heal_guard() {
    local guard="${BIN_DIR}/warp-heal"
    local hs="${SYSTEMD_DIR}/warp-heal.service"
    local ht="${SYSTEMD_DIR}/warp-heal.timer"

    if ! command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli absent — no heal-guard"
        return 0
    fi

    cat > "$guard" <<'HEALEOF'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
  log "registration missing — re-registering"
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 5
fi
eg=$(curl -s --max-time 8 -x socks5h://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo "")
case "$eg" in
  104.28.*|162.159.*|172.64.*) log "heal-ok: egress $eg" ;;
  *) log "WARN: egress '$eg' not Cloudflare — run setup" ;;
esac
HEALEOF
    chmod +x "$guard"

    [ -f "$hs" ] || cat > "$hs" <<'HSEOF'
[Unit]
Description=WARP heal-guard (daily)
[Service]
Type=oneshot
ExecStart=/var/tmp/warp-heal
HSEOF
    sed -i "s|ExecStart=.*|ExecStart=${BIN_DIR}/warp-heal|" "$hs"

    [ -f "$ht" ] || cat > "$ht" <<'HTEOF'
[Unit]
Description=Run WARP heal-guard daily
[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
HTEOF

    systemctl_cmd daemon-reload
    systemctl_cmd enable --now warp-heal.timer >/dev/null 2>&1 || true
    systemctl_cmd is-active --quiet warp-heal.timer && log "warp-heal.timer active (daily guard)" || log "warp-heal.timer not running"
}

# ---------------------------------------------------------------------------
# 6b. auto-sync free models (supervised probe) — daily timer
# ---------------------------------------------------------------------------
deploy_sync() {
    local sync="${BIN_DIR}/sync-models.sh"
    if [ ! -f "$sync" ]; then
        cat > "$sync" <<'SYNCEOF'
#!/usr/bin/env bash
# supervised free-model sync — see opencode-proxy-rotator repo.
set -euo pipefail
PROXY_BIN="$(dirname "$(readlink -f "$0")")/oc-free-proxy.js"
MODELS_FILE="$(dirname "$PROXY_BIN")/free-models.json"
UPSTREAM_LIST="https://opencode.ai/zen/v1/models"
UPSTREAM_CHAT="https://opencode.ai/zen/v1/chat/completions"
UPSTREAM_AUTH="${OC_UPSTREAM_AUTH:-}"
PROBE_TIMEOUT="30"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
restart_proxy() {
    if [ "$(id -u)" -eq 0 ]; then systemctl restart oc-free-proxy >/dev/null 2>&1 || true
    else systemctl --user restart oc-free-proxy >/dev/null 2>&1 || true; fi
}
probe_model() {
    local model="$1" auth_hdr=() body resp
    [ -n "$UPSTREAM_AUTH" ] && auth_hdr=(-H "Authorization: Bearer ${UPSTREAM_AUTH}")
    body="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"
    resp=$(curl -sk --max-time "$PROBE_TIMEOUT" -o /tmp/probe-body.json -w '%{http_code}' \
        -X POST "$UPSTREAM_CHAT" -H "Content-Type: application/json" "${auth_hdr[@]}" -d "$body" 2>/dev/null || echo "000")
    [ "$resp" = "200" ] && grep -q '"choices"' /tmp/probe-body.json 2>/dev/null
}
fetch_free_models() {
    curl -sk --max-time 20 "$UPSTREAM_LIST" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d.get('data', []):
        if m.get('id','').endswith('-free'): print(m['id'])
except Exception: pass"
}
log "=== supervised free-model sync ==="
mapfile -t CANDIDATES < <(fetch_free_models)
[ "${#CANDIDATES[@]}" -eq 0 ] && { log "ERROR: no free models upstream — keeping existing allowlist"; exit 1; }
log "candidates (${#CANDIDATES[@]}): ${CANDIDATES[*]}"
GOOD=()
for m in "${CANDIDATES[@]}"; do
    if probe_model "$m"; then log "  OK   $m"; GOOD+=("$m"); else log "  SKIP $m (probe failed)"; fi
done
rm -f /tmp/probe-body.json
[ "${#GOOD[@]}" -eq 0 ] && { log "ERROR: no model passed probing — keeping existing allowlist"; exit 1; }
set +e
python3 - "$MODELS_FILE" "${GOOD[@]}" <<'PY'
import json, sys
path = sys.argv[1]; models = sys.argv[2:]
try: old = json.load(open(path))
except Exception: old = None
if old == models: sys.exit(0)
json.dump(models, open(path, "w"), indent=2)
sys.exit(1)
PY
changed=$?
set -e
if [ "$changed" -eq 0 ]; then log "allowlist unchanged (${#GOOD[@]} models) — no restart"
else log "wrote ${#GOOD[@]} working models to $MODELS_FILE: ${GOOD[*]}"; restart_proxy; log "restarted oc-free-proxy"; fi
log "=== sync complete ==="
SYNCEOF
        chmod +x "$sync"
        log "wrote model sync $sync"
    fi

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

# ---------------------------------------------------------------------------
# 7. opencode env (content-checked, path-aware)
# ---------------------------------------------------------------------------
write_opencode_env() {
    # Root: write /etc/profile.d/opencode-proxy.sh (auto-sourced by login shells).
    # Non-root: append directly to ~/.profile (a single file, not a dir).
    local envfile
    if is_root; then
        envfile="/etc/profile.d/opencode-proxy.sh"
        mkdir -p /etc/profile.d
        write_env_to "$envfile"
    else
        envfile="${HOME}/.profile"
        write_env_to "$envfile"
        log "opencode proxy env in ~/.profile (source it or relogin)"
    fi
}

write_env_to() {
    local tgt="$1"
    local want="OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    if [ -f "$tgt" ] && grep -qF "$want" "$tgt"; then
        log "opencode proxy env already correct ($tgt)"
        return 0
    fi
    {
        echo "# opencode -> oc-free-proxy -> WARP (opencode-proxy-rotator)"
        echo "export ALL_PROXY=socks5://127.0.0.1:${SOCKS_PORT}"
        echo "export OPENCODE_BASE_URL=http://127.0.0.1:${PROXY_PORT}/v1"
    } >> "$tgt"
    log "wrote opencode proxy env to $tgt"
}

proxy_healthy() {
    curl -s --max-time 6 "http://127.0.0.1:${PROXY_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    # ensure a systemd user unit scope can run without lingering session
    if ! is_root; then
        local uid
        uid="$(id -u)"
        export XDG_RUNTIME_DIR="/run/user/$uid"
    fi
    log "mode: $(is_root && echo SYSTEM-Root || echo USER-nonroot)"

    kill_squatters
    start_warp
    kill_squatters
    ensure_oc_proxy_js
    deploy_oc_unit
    deploy_rotation
    deploy_heal_guard
    deploy_sync
    write_opencode_env
    sleep 2

    echo "=== models via proxy ==="
    curl -s --max-time 8 "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null | grep -oP '"id":"\K[^"]+' | sed 's/^/  - /' || true

    echo -n "egress via proxy: "
    local eg
    eg=$(curl -s --max-time 8 -x socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org 2>/dev/null || echo "")
    echo "$eg"
    local ph="no"; proxy_healthy && ph="yes"

    if [ "$ph" = "yes" ] && [ -n "$eg" ]; then
        log "proxy OK (health=yes), egress=$eg"
        # WARP-specific egress only when warp present AND Cloudflare
        command -v warp-cli >/dev/null 2>&1 && [[ "$eg" == 104.28.* ]] \
            && log "ALL GREEN: WARP egress $eg" || log "(no WARP tunnel or non-Cloudflare egress — direct is fine)"
    else
        die "CHECK FAILED: proxy_healthy=$ph egress='$eg'"
    fi
}

main "$@"