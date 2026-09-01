# Changelog

All notable changes to the opencode-proxy-rotator project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-09-01

### Added
- **Internet watchdog**: `internet-watchdog.sh` runs every 3 seconds to check:
  - Can we reach opencode.ai? (upstream check)
  - Is WARP tunnel alive? (port 40000 listening)
  - Is proxy healthy? (/health endpoint)
  - Is egress IP valid? (Cloudflare range)
- **Auto-heal actions**:
  - Proxy down → restart proxy
  - WARP down → restart warp-svc
  - Upstream unreachable → rotate WARP
  - Egress not Cloudflare → rotate WARP
- **Consecutive failure tracking**: Actions only trigger after 3 consecutive failures
- **Watchdog logging**: All checks logged to `/var/log/oc-proxy/watchdog.jsonl`

## [1.3.0] - 2026-09-01

### Added
- **Post-rotate verification**: `post-rotate-verify.sh` verifies WARP rotation actually changed the IP
- **Config drift checker**: `config-drift-check.sh` runs every 5 minutes to auto-redeploy if code broken
- **Drift logging**: All drift events logged to `/var/log/oc-proxy/drift.jsonl`

## [1.2.0] - 2026-09-01

### Added
- **Response monitoring**: Track per-model health (failure counts, last error, last success)
- **Auto-rotate on rate limit**: When `FreeUsageLimitError` is detected, automatically trigger WARP rotation
- **Structured logging**: Log all errors to `/var/log/oc-proxy/proxy.jsonl` and rotation events to `rotation.jsonl`
- **Model health endpoint**: `/health/models` shows per-model status, failure counts, and error details

## [1.1.0] - 2026-09-01

### Added
- **Hermes Agent headers in sync-probe**: `sync-models.sh` now sends Hermes Agent headers when probing models
- **Improved probe logic**: Accepts responses with `content: null` (common with `max_tokens=1`)

## [1.0.0] - 2026-08-30

### Added
- Initial release with WARP-routed proxy, model allowlist, and healthcheck.
