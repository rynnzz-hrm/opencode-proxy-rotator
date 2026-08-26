#!/usr/bin/env node
// oc-free-proxy — Express proxy for OpenCode API (rynn-zeyn, fixed 2026-08-01)
// FIXES vs original: bind 127.0.0.1 (was 0.0.0.0 — unauthenticated LAN proxy),
// dead session-rotation + rate-limit stubs removed, unhandledRejection guard added,
// /zen path + auth-strip kept (verified working).

const express = require("express");
const { createProxyMiddleware } = require("http-proxy-middleware");
const https = require("https");
const os = require("os");
const fs = require("fs");
const path = require("path");
const { SocksProxyAgent } = require("socks-proxy-agent");

const app = express();
const PORT = 6446;
const BIND_HOST = "127.0.0.1"; // FIX: loopback only — Hermes is on the same box
// Real API lives under /zen — incoming /v1/* maps to https://opencode.ai/zen/v1/*
const TARGET = "https://opencode.ai/zen";
// Optional: set OC_UPSTREAM_AUTH to a real key to unlock paid/mimo/hy3 models.
// Free models work WITHOUT auth (anonymous tier). Never send a fake key upstream.
const UPSTREAM_AUTH = process.env.OC_UPSTREAM_AUTH || "";

// FIX 2026-08-09: node's https/http DO NOT honor ALL_PROXY env — the proxy was
// egressing DIRECT via the ISP IP, whose opencode.ai/zen free quota was burned
// ("FreeUsageLimitError"). Route ALL outbound through warp-svc's SOCKS5
// (:40000, Cloudflare WARP) explicitly. verify: rate cap below.
const WARP_SOCKS = "socks5://127.0.0.1:40000";
const socksAgent = new SocksProxyAgent(WARP_SOCKS);

// FALLBACK POLICY (2026-08-16 audit round 3): when warp-svc is unreachable the
// proxy MAY egress direct via the ISP IP — which burns the opencode free quota
// (20h lockout). Default is FAIL-CLOSED (502) so a random device never silently
// burns its ISP IP. Set OC_ALLOW_DIRECT_FALLBACK=1 ONLY on the box you trust +
// monitor; the healthcheck alerts either way.
const ALLOW_DIRECT_FALLBACK = process.env.OC_ALLOW_DIRECT_FALLBACK === "1";
let warpDown = false;

// AUTO-ROUTE (2026-08-13, hardened round 3): when warp-svc is down, behavior
// depends on OC_ALLOW_DIRECT_FALLBACK: set => direct/ISP egress (proxy target
// :6446 stays alive for ALL_PROXY clients — laptop keeps internet); unset
// (default) => FAIL CLOSED (502), so a random device never silently burns the
// ISP IP's opencode quota. egressMode toggles per refreshIp() probe.
let egressMode = "warp";
// Egress dispatch (2026-08-16 audit rounds 2 & 5): a REAL https.Agent subclass
// that delegates per-mode to socksAgent (WARP) or directAgent (ISP fallback).
// A plain-object dispatcher failed https.request's TLS path with EPROTO
// wrong-version (Node needs an Agent instance for proper socket creation), so
// the subclass pattern is kept — it's the standard socks-proxy-agent interop.
const directAgent = new https.Agent({ keepAlive: true });
class EgressAgent extends https.Agent {
    constructor() { super({ keepAlive: true }); }
    addRequest(req, opts) {
        return (egressMode === "warp" ? socksAgent : directAgent).addRequest(req, opts);
    }
}
const egressAgent = new EgressAgent();

// --- per-IP usage tracker (2026-08-09) --------------------------------------
// AUDIT FIX 2026-08-16: track BOTH egress paths (WARP + direct/ISP) and label
// the ACTIVE one honestly. The old version only ever set usage.ip from the
// socks probe, so mode=direct showed a STALE WARP IP while the ISP IP burned
// quota invisibly (the 20h-lockout vector). Window resets on mode flip too.
const HOME_DIR = process.env.HOME || os.homedir();
const USAGE_FILE = path.join(HOME_DIR, ".oc-usage.json");
const HISTORY_FILE = path.join(HOME_DIR, ".oc-usage-history.jsonl");
const ALERT_TOKENS = parseInt(process.env.USAGE_ALERT_TOKENS || "0", 10) || 0;
let usage = { ip: "unknown", windowStart: Date.now(), requests: 0, inBytes: 0, outBytes: 0, alerted: false };
let warpIp = "";
let directIp = "";
function loadUsage() { try { const d = JSON.parse(fs.readFileSync(USAGE_FILE, "utf8")); usage = { ...usage, ...d }; } catch (e) {} }
function saveUsage() { try { fs.writeFileSync(USAGE_FILE, JSON.stringify(usage)); } catch (e) {} }
function recordHistory() { try { fs.appendFileSync(HISTORY_FILE, JSON.stringify(usage) + "\n"); } catch (e) {} }
function estTokens() { return Math.round((usage.inBytes + usage.outBytes) / 4); }
function resetUsageWindow(ip) {
    if (usage.ip && usage.ip !== "unknown") { recordHistory(); }
    usage.ip = ip || "unknown";
    usage.windowStart = Date.now();
    usage.requests = 0; usage.inBytes = 0; usage.outBytes = 0; usage.alerted = false;
    saveUsage();
}
function checkAlert() {
    if (ALERT_TOKENS && !usage.alerted && estTokens() >= ALERT_TOKENS) {
        usage.alerted = true;
        console.warn(`[${new Date().toISOString()}] USAGE ALERT: ip ${usage.ip} est ${estTokens()} tokens >= ${ALERT_TOKENS} — rotate WARP before this IP locks (FreeUsageLimitError ~20h)`);
        saveUsage();
    }
}
function probeDirectIp() {
    const req = https.get({ hostname: "ipinfo.io", path: "/ip", timeout: 8000 }, (res) => {
        let d = "";
        res.on("data", (c) => d += c);
        res.on("end", () => {
            const ip = d.trim();
            if (ip) {
                directIp = ip;
                // reset ONLY on change — a stable direct IP must not zero the
                // window every 10 min (that would fragment history + kill the alert)
                if (egressMode === "direct" && ip !== usage.ip) { resetUsageWindow(ip); }
            }
        });
    });
    req.on("error", () => { /* direct probe failed — keep previous directIp */ });
}
function refreshIp() {
    const req = https.get({ hostname: "ipinfo.io", path: "/ip", agent: socksAgent, timeout: 8000 }, (res) => {
        let d = "";
        res.on("data", (c) => d += c);
        res.on("end", () => {
            const ip = d.trim();
            if (ip) {
                warpIp = ip;
                warpDown = false;
                if (egressMode !== "warp") {
                    egressMode = "warp";
                    console.log(`[${new Date().toISOString()}] egress -> WARP (ip ${ip})`);
                    resetUsageWindow(ip);
                } else if (ip !== usage.ip) {
                    resetUsageWindow(ip);
                }
            }
        });
    });
    req.on("error", () => {
        warpDown = true;
        if (egressMode !== "direct") {
            if (!ALLOW_DIRECT_FALLBACK) {
                // fail closed (audit round 3): requests keep routing via the
                // dead (warp) agent and 502 — visible, quota-safe, no ISP burn
                console.warn(`[${new Date().toISOString()}] WARP unreachable + OC_ALLOW_DIRECT_FALLBACK unset — FAILING CLOSED (502s). Set OC_ALLOW_DIRECT_FALLBACK=1 to allow ISP fallback.`);
                return;
            }
            egressMode = "direct";
            console.warn(`[${new Date().toISOString()}] egress -> DIRECT (warp-svc unreachable) — auto-route fallback (ISP IP: watch quota)`);
            // Race fix (2026-08-16 audit): label the flip NOW but DON'T zero the
            // window here — probeDirectIp() confirms the real direct IP and
            // resets once on change. Resetting twice fragments usage history.
            usage.ip = directIp || "direct-unknown";
            saveUsage();
        }
    });
    probeDirectIp();
}
loadUsage();
refreshIp();
setInterval(() => { saveUsage(); refreshIp(); }, 600000); // re-check IP every 10 min
setInterval(() => { checkAlert(); saveUsage(); }, 15000);  // alert + persist every 15s

// parse JSON bodies (needed for the model gate below)
// FIX 2026-08-07: express.json() defaults to 100kb — Sye's Telegram context
// payloads exceed that and got 413. Raise to 25mb (matches upstream limits).
app.use(express.json({ limit: "25mb" }));

// Proxy-side rate cap (2026-08-09): opencode.ai/zen free tier has an UNDISCLOSED
// per-IP rolling-24h quota; hitting it locks the IP ~20h ("Free usage exceeded,
// add credits [retrying in 20h]"). Cap total demand per window so the proxy
// returns a quick 429 (seconds of retry) instead of a 20h upstream lockout.
// All clients are local (127.0.0.1) so this throttles total proxy throughput.
const rateLimit = require("express-rate-limit");
const rlMin = rateLimit({ windowMs: 60_000, limit: 45, standardHeaders: true, legacyHeaders: false });
const rlHour = rateLimit({ windowMs: 3_600_000, limit: 1800, standardHeaders: true, legacyHeaders: false });
const rlDay = rateLimit({ windowMs: 86_400_000, limit: 2400, standardHeaders: true, legacyHeaders: false });
app.use("/v1", rlMin, rlHour, rlDay);

process.on("unhandledRejection", (e) => {
    console.error(`[${new Date().toISOString()}] unhandledRejection: ${e.message}`);
});

// Model filtering — anonymous free tier always; paid only when a real key is set
const FREE_MODELS = [
    // deepseek-v4-flash-free removed 2026-08-26: upstream Console retired it
    // ("Upstream request failed: Model is unavailable"); advertising a dead
    // model makes /v1/models lie and the gate forwards 400s. Same class of
    // death as north-mini-code-free (2026-08-07). Don't re-add unless probed.
    "ling-3.0-flash-free",
    "mimo-v2.5-free",
    "nemotron-3-ultra-free",
    "laguna-s-2.1-free",
    // north-mini-code-free removed 2026-08-07: listed upstream but 401s on
    // anonymous tier even direct — advertising it breaks clients (auto-sync).
];
const PAID_MODELS = ["glm-5.2", "deepseek-v4-pro", "kimi-k3", "qwen3.6-plus", "minimax-m3", "gpt-5.6-sol", "mimo-v2-free", "hy3-free"]; // need OC_UPSTREAM_AUTH

function allowedModels() {
    return UPSTREAM_AUTH ? [...FREE_MODELS_LIVE, ...PAID_MODELS] : FREE_MODELS_LIVE;
}

// AUTO-SYNC (Design B 2026-08-07): if a free-models.json sits next to this
// script, it overrides FREE_MODELS. sync-models.sh writes only models it has
// probed (real chat) as working. The built-in list remains the fallback when
// the file is absent or malformed.
const MODELS_FILE = path.join(__dirname, "free-models.json");
function loadFreeModels() {
    try {
        const raw = fs.readFileSync(MODELS_FILE, "utf8");
        const arr = JSON.parse(raw);
        if (Array.isArray(arr) && arr.length > 0 && arr.every(m => typeof m === "string")) {
            return arr;
        }
    } catch (e) { /* fall through to built-in */ }
    return FREE_MODELS;
}
let FREE_MODELS_LIVE = loadFreeModels();

// Health check (BEFORE catch-all proxy)
app.get("/health", (req, res) => res.json({ status: "ok" }));

// Model list endpoint (BEFORE catch-all proxy)
// AUDIT FIX 2026-08-16: cache upstream /v1/models for 60s — the old version hit
// upstream on EVERY request (quota burn outside tracker/caps). On upstream
// failure, serve the stale cache if present (never advertise a broken empty list).
const MODELS_CACHE_TTL = 60_000;
let modelsCache = { data: null, at: 0 };
app.get("/v1/models", (req, res) => {
    usage.requests += 1; // audit fix: /v1/models polls were untracked traffic
    if (modelsCache.data && Date.now() - modelsCache.at < MODELS_CACHE_TTL) {
        return res.json(modelsCache.data);
    }
    const options = {
        hostname: "opencode.ai",
        path: "/zen/v1/models",
        method: "GET",
        headers: {},
        agent: egressAgent,
    };
    if (UPSTREAM_AUTH) options.headers.Authorization = UPSTREAM_AUTH;
    const upstreamReq = https.request(options, (upRes) => {
        let data = "";
        upRes.on("data", (chunk) => data += chunk);
        upRes.on("end", () => {
            try {
                const models = JSON.parse(data);
                // AUDIT FIX (round 5): only cache a REAL model list. An error
                // body (e.g. upstream 429 {"error":...}) parses as JSON but has
                // no data array — the old code cached it as an empty list for
                // 60s, poisoning /v1/models exactly when upstream is degraded.
                if (Array.isArray(models.data)) {
                    const allow = allowedModels();
                    const body = { data: models.data.filter(m => allow.includes(m.id)) };
                    modelsCache = { data: body, at: Date.now() };
                    return res.json(body);
                }
                // upstream error body — serve stale cache, else the allowlist
                // (what the gate actually permits), WITHOUT caching the lie
                if (modelsCache.data) return res.json(modelsCache.data);
                return res.json({ data: allowedModels() });
            } catch (e) {
                if (modelsCache.data) return res.json(modelsCache.data); // stale on parse error
                res.json({ data: [] });
            }
        });
    });
    upstreamReq.on("error", () => {
        if (modelsCache.data) return res.json(modelsCache.data); // stale on network error
        res.json({ data: [] });
    });
    upstreamReq.end();
});

app.get("/usage", (req, res) => {
    checkAlert();
    res.json({
        mode: egressMode,
        ip: usage.ip,            // ACTIVE egress IP (warp IP when warp, ISP IP when direct)
        warpIp: warpIp || null,
        directIp: directIp || null,
        directFallback: egressMode === "direct",
        failClosed: warpDown && !ALLOW_DIRECT_FALLBACK,
        fallbackAllowed: ALLOW_DIRECT_FALLBACK,
        windowStart: new Date(usage.windowStart).toISOString(),
        windowSeconds: Math.round((Date.now() - usage.windowStart) / 1000),
        requests: usage.requests,
        inBytes: usage.inBytes,
        outBytes: usage.outBytes,
        estTokens: estTokens(),
        alertTokens: ALERT_TOKENS || null,
        alertFired: usage.alerted,
    });
});

// Model gate (TASK 1 2026-08-07): reject chat requests for models not in the
// allowlist BEFORE they hit upstream. Anonymous tier = FREE_MODELS only; with
// OC_UPSTREAM_AUTH, paid models are allowed too (matches /v1/models listing).
app.post("/v1/chat/completions", (req, res, next) => {
    usage.requests += 1;
    usage.inBytes += req.headers["content-length"]
        ? parseInt(req.headers["content-length"], 10)
        : Buffer.byteLength(JSON.stringify(req.body || ""));
    const model = req.body && req.body.model;
    if (model && !allowedModels().includes(model)) {
        return res.status(400).json({
            error: {
                type: "invalid_request_error",
                message: `model '${model}' is not allowed. Available: ${allowedModels().join(", ")}`
            }
        });
    }
    next();
});

// Proxy middleware (catch-all LAST)
app.use("/", createProxyMiddleware({
    target: TARGET,
    changeOrigin: true,
    agent: egressAgent,
    on: {
        error: (err, req, res) => {
            console.error(`[${new Date().toISOString()}] Proxy error:`, err.message);
            res.status(502).json({ error: "proxy_error", message: err.message });
        },
        proxyRes: (proxyRes) => {
            // usage tracker: count response bytes without buffering the stream
            proxyRes.on("data", (chunk) => { usage.outBytes += chunk.length; });
        },
        proxyReq: (proxyReq, req) => {
            // Audit fix: count proxied traffic that is NOT /v1/chat/completions
            // (the gate counted chat already) — /usage must see ALL requests.
            if (!/\/v1\/chat\/completions$/.test(req.url)) {
                usage.requests += 1;
                usage.inBytes += req.headers["content-length"]
                    ? parseInt(req.headers["content-length"], 10)
                    : Buffer.byteLength(JSON.stringify(req.body || {}));
            }
            // Strip the client's Authorization header — it would be forwarded upstream
            // and cause 401 Invalid API key (the free tier is anonymous).
            proxyReq.removeHeader("Authorization");
            proxyReq.removeHeader("authorization");

            // Inject upstream auth ONLY if a real key is configured
            if (UPSTREAM_AUTH) {
                proxyReq.setHeader("Authorization", UPSTREAM_AUTH);
            }

            // express.json() already consumed the request body; forward it upstream
            if (req.body && Object.keys(req.body).length > 0) {
                const body = JSON.stringify(req.body);
                proxyReq.setHeader("Content-Length", Buffer.byteLength(body));
                proxyReq.write(body);
                proxyReq.end();
            }
        }
    }
}));

app.listen(PORT, BIND_HOST, () => {
    console.log(`[${new Date().toISOString()}] oc-free-proxy listening on ${BIND_HOST}:${PORT}`);
});
