# opencode-proxy-rotator

Rotates the egress IP for OpenCode's traffic through Cloudflare WARP. One box,
three pieces: oc-free-proxy on :6446 (the OpenAI-compatible surface agents talk
to), warp-svc on :40000 (the WARP SOCKS5), and a timer that re-registers the
WARP account every 20 minutes to get a fresh Cloudflare IP.

```
agent → oc-free-proxy :6446 ── socks-proxy-agent ──► warp-svc :40000 ──► opencode.ai/zen
```

> NOTE (2026-08-11): the proxy pins its outbound through the WARP SOCKS with
> `socks-proxy-agent`. Node's http/https IGNORE `ALL_PROXY`, so the env var is
> vestigial — never rely on it for the proxy's egress. Without the explicit
> agent, the proxy egresses direct via the ISP IP, whose opencode free-tier
> quota burns → `FreeUsageLimitError` 429s and ~20h lockouts.

## Install

```bash
./setup.sh                 # root or non-root; runs modules/01..07 in order
```

Modules (each standalone-testable):

| Module | What it does |
|--------|--------------|
| `01-warp.sh` | kill orphan node squatters, bring up WARP (registration, drop-in, bind) |
| `02-proxy.sh` | install `oc-free-proxy.js` (copied from repo root — no heredoc) + npm deps + unit |
| `03-rotation.sh` | 20-min WARP rotation timer (registration-ID verified) + daily heal-guard |
| `04-sync.sh` | supervised free-model sync (merge-only allowlist) + daily timer |
| `05-env.sh` | opencode env (`OPENCODE_BASE_URL`) |
| `06-verify.sh` | health, models list, egress check (3-prefix) |
| `07-healthcheck.sh` | 1-min healthcheck + AUTO-HEAL: restart proxy / rotate WARP on deep FAIL |

The proxy requires npm deps: `express http-proxy-middleware socks-proxy-agent express-rate-limit`.

## The proxy (oc-free-proxy.js)

- **Free tier is anonymous** — no API key. The proxy strips client Authorization
  headers; a dummy key upstream = 401. `OC_UPSTREAM_AUTH` unlocks paid models only.
- **Model gate** — `/v1/chat/completions` with a model outside the allowlist gets
  a clean 400 (no upstream round-trip).
- **Rate caps** — 45/min, 1800/hr, 2400/day per client (all local = total
  throughput). 429 here is seconds of retry; the upstream cap is a ~20h lockout.
- **Usage tracker** — every request/byte counted and labeled with the current
  WARP egress IP. `GET /v1/usage` (or /usage) shows: ip, window start, requests,
  in/out bytes, estTokens (bytes/4), alert state. Persists to `~/.oc-usage.json`
  (+ history on IP change). Set `USAGE_ALERT_TOKENS` (e.g. 5000000) to log a
  one-shot `USAGE ALERT` warning when a window crosses it.
- **/v1/models** — lists only allowlisted models (auto-sync can extend the list).

## Rotation semantics

`warp-rotate` deletes + re-registers the WARP identity every 20 min. The visible
egress IP can REPEAT across cycles — the Cloudflare free pool is small. The real
proof of rotation is the **registration ID** changing (logged as
`registration <OLD> -> <NEW>`), not the IP. Rotation is skipped while traffic is
flowing on :6446 (guard), so it may defer until idle.

## Healthcheck & auto-heal

`proxy-healthcheck.timer` runs every minute: passive `/health` + Cloudflare
egress checks; every 30 min a real chat completion through :6446. On deep FAIL:
restart the proxy, and if egress is unchanged, rotate WARP — with a 20-min
cooldown so a quota-looping IP isn't hammered. Failures append to
`~/logs/proxy-healthcheck-failures.txt`.

## Model sync (merge-only)

`sync-models.sh` probes upstream `*-free` models (through the same WARP socks)
and MERGES the passing set into `free-models.json` — it can ADD, never REMOVE.
This is deliberate: probes fail during IP rate-limits, and a shrunk allowlist
400s clients ("model not allowed") exactly when the proxy is already broken.

## Operator notes

- **Fallback policy (fail-closed default).** If the WARP SOCKS dies, the proxy
  normally FAILS CLOSED: requests get a visible 502 instead of silently
  egressing via the ISP IP (whose opencode free quota would burn → ~20h 429
  lockout). To allow the ISP fallback on a box you trust and monitor, set
  `OC_ALLOW_DIRECT_FALLBACK=1` when installing (or add it to the unit's
  Environment). `/usage` reports `failClosed` / `directFallback` /
  `fallbackAllowed` so you can see which mode you're in.
- **ALL_PROXY is conditional.** `05-env.sh` only exports ALL_PROXY while new
  shells can actually reach the WARP SOCKS (`ss -tln` check). Proxy down on a
  device => no ALL_PROXY => curl/git/npm just work direct instead of hanging
  into a dead SOCKS. Proxy up => routed as usual.
- WARP re-registration drops the SOCKS socket briefly (~8-30s); long-lived
  clients (Telegram long-poll, streams) may reconnect. If a user's internet
  routes through this box, they'll see the same blip.
- Same-IP rotation repeats are normal — check the registration ID, not the IP.
- `ALL_PROXY` in the profile is vestigial for node (node ignores it); keep it
  for curl/wget-based tooling.
