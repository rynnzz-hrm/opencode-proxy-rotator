#!/usr/bin/env node
// oc-free-proxy — Express proxy for OpenCode API (rynn-zeyn, fixed 2026-08-01)
// FIXES vs original: bind 127.0.0.1 (was 0.0.0.0 — unauthenticated LAN proxy),
// dead session-rotation + rate-limit stubs removed, unhandledRejection guard added,
// /zen path + auth-strip kept (verified working).

const express = require("express");
const { createProxyMiddleware } = require("http-proxy-middleware");
const https = require("https");

const app = express();
const PORT = 6446;
const BIND_HOST = "127.0.0.1"; // FIX: loopback only — Hermes is on the same box
// Real API lives under /zen — incoming /v1/* maps to https://opencode.ai/zen/v1/*
const TARGET = "https://opencode.ai/zen";
// Optional: set OC_UPSTREAM_AUTH to a real key to unlock paid/mimo/hy3 models.
// Free models work WITHOUT auth (anonymous tier). Never send a fake key upstream.
const UPSTREAM_AUTH = process.env.OC_UPSTREAM_AUTH || "";

process.on("unhandledRejection", (e) => {
    console.error(`[${new Date().toISOString()}] unhandledRejection: ${e.message}`);
});

// Model filtering — anonymous free tier always; paid only when a real key is set
const FREE_MODELS = [
    "deepseek-v4-flash-free",
    "ling-3.0-flash-free",
    "mimo-v2.5-free",
    "nemotron-3-ultra-free",
    "laguna-s-2.1-free",
    // north-mini-code-free removed 2026-08-07: listed upstream but 401s on
    // anonymous tier even direct — advertising it breaks clients (auto-sync).
];
const PAID_MODELS = ["glm-5.2", "deepseek-v4-pro", "kimi-k3", "qwen3.6-plus", "minimax-m3", "gpt-5.6-sol", "mimo-v2-free", "hy3-free"]; // need OC_UPSTREAM_AUTH

function allowedModels() {
    return UPSTREAM_AUTH ? [...FREE_MODELS, ...PAID_MODELS] : FREE_MODELS;
}

// Health check (BEFORE catch-all proxy)
app.get("/health", (req, res) => res.json({ status: "ok" }));

// Model list endpoint (BEFORE catch-all proxy)
app.get("/v1/models", (req, res) => {
    const options = {
        hostname: "opencode.ai",
        path: "/zen/v1/models",
        method: "GET",
        headers: {},
    };
    if (UPSTREAM_AUTH) options.headers.Authorization = UPSTREAM_AUTH;
    const upstreamReq = https.request(options, (upRes) => {
        let data = "";
        upRes.on("data", (chunk) => data += chunk);
        upRes.on("end", () => {
            try {
                const models = JSON.parse(data);
                const allow = allowedModels();
                res.json({ data: (models.data || []).filter(m => allow.includes(m.id)) });
            } catch (e) {
                res.json({ data: [] });
            }
        });
    });
    upstreamReq.on("error", () => res.json({ data: [] }));
    upstreamReq.end();
});

// Proxy middleware (catch-all LAST)
app.use("/", createProxyMiddleware({
    target: TARGET,
    changeOrigin: true,
    on: {
        error: (err, req, res) => {
            console.error(`[${new Date().toISOString()}] Proxy error:`, err.message);
            res.status(502).json({ error: "proxy_error", message: err.message });
        },
        proxyReq: (proxyReq) => {
            // Strip the client's Authorization header — it would be forwarded upstream
            // and cause 401 Invalid API key (the free tier is anonymous).
            proxyReq.removeHeader("Authorization");
            proxyReq.removeHeader("authorization");

            // Inject upstream auth ONLY if a real key is configured
            if (UPSTREAM_AUTH) {
                proxyReq.setHeader("Authorization", UPSTREAM_AUTH);
            }
        }
    }
}));

app.listen(PORT, BIND_HOST, () => {
    console.log(`[${new Date().toISOString()}] oc-free-proxy listening on ${BIND_HOST}:${PORT}`);
});
