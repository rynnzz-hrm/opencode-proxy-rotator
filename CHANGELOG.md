# Changelog

All notable changes to the opencode-proxy-rotator project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-01

### Added
- **Hermes Agent headers in sync-probe**: `sync-models.sh` now sends Hermes Agent headers (`HTTP-Referer`, `X-Title`, `User-Agent`) when probing models. This fixes detection of models like `ling-3.0-flash-fin-free` that require these headers to work.
- **Improved probe logic**: The model probe now accepts responses with `content: null` (common with `max_tokens=1`). A 200 response with a non-empty `choices` array is sufficient to confirm model availability.

### Fixed
- **ling-3.0-flash-fin-free detection**: Previously failed probing because the probe checked for non-empty `content` field. With `max_tokens=1`, the model returns `content: null` but is still available. Fixed by checking for non-empty `choices` array instead.
- **mimo-v2.5-free rate limit handling**: Models that are rate-limited on the current WARP IP are now correctly skipped during probing (not permanently removed).

### Changed
- **Probe response validation**: Simplified from two separate checks (grep pattern + Python content check) to a single Python check that validates: (1) HTTP 200, (2) no error in response body, (3) non-empty choices array.

## [1.0.0] - 2026-08-30

### Added
- Initial release with WARP-routed proxy, model allowlist, and healthcheck.

### Features
- Express proxy on port 6446 forwarding to opencode.ai/zen
- Cloudflare WARP SOCKS5 egress for IP rotation
- Model allowlist with merge-only strategy (never removes working models)
- 3-strike eviction for consistently failing models
- Passive healthcheck (1-min) + deep chat check (30-min)
- Auto-heal: restart proxy / rotate WARP on failure
- Rate limit protection: local rate caps to prevent 20h lockout
- Usage tracking with alert thresholds

### Security
- Bind to 127.0.0.1 only (no LAN exposure)
- Strip client Authorization header (free tier is anonymous)
- Fail-closed default when WARP is unreachable
