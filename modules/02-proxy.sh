#!/usr/bin/env bash
# 02-proxy.sh — install oc-free-proxy.js + systemd unit + npm deps.

[ -n "${COMMON_LOADED:-}" ] || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
export COMMON_LOADED=1

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
const fs = require("fs");
const path = require("path");
const app = express();
const PORT = 6446;
const BIND_HOST = "127.0.0.1";
const TARGET = "https://opencode.ai/zen";
const UPSTREAM_AUTH = process.env.OC_UPSTREAM_AUTH || "";
process.on("unhandledRejection", (e) => console.error(`[${new Date().toISOString()}] unhandledRejection: ${e.message}`));
const FREE_MODELS = ["deepseek-v4-flash-free","ling-3.0-flash-free","mimo-v2.5-free","nemotron-3-ultra-free","laguna-s-2.1-free"];
const PAID_MODELS = ["glm-5.2","deepseek-v4-pro","kimi-k3","qwen3.6-plus","minimax-m3","gpt-5.6-sol","mimo-v2-free","hy3-free"];
// AUTO-SYNC: if free-models.json sits next to this script, it overrides FREE_MODELS
const MODELS_FILE = path.join(__dirname, "free-models.json");
function loadFreeModels() {
    try {
        const arr = JSON.parse(fs.readFileSync(MODELS_FILE, "utf8"));
        if (Array.isArray(arr) && arr.length > 0 && arr.every(m => typeof m === "string")) return arr;
    } catch (e) { /* fall through */ }
    return FREE_MODELS;
}
let FREE_MODELS_LIVE = loadFreeModels();
function allowedModels(){ return UPSTREAM_AUTH ? [...FREE_MODELS_LIVE,...PAID_MODELS] : FREE_MODELS_LIVE; }
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