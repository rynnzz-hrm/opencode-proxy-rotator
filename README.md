# opencode-proxy-rotator

Rotates the egress IP for OpenCode's traffic through Cloudflare WARP. One box, three pieces: oc-free-proxy on :6446 (the OpenAI-compatible surface opencode talks to), warp-svc on :40000 (the WARP SOCKS5), and a systemd timer that re-registers the WARP account every 20 minutes to get a fresh Cloudflare IP.

This repo exists because the previous design stopped working. That setup generated 30 WireGuard configs and rotated between them. Cloudflare accepted the registrations but refused the handshakes, all except one. So the script spent its time importing tunnels that never came up. The replacement throws away the WireGuard pool entirely and uses warp-cli, which is the tool Cloudflare ships for this.

## Install — no sudo needed

Run it as a normal user. It installs the proxy itself (oc-free-proxy.js + npm deps into ~/.opencode-proxy), writes user-level systemd units, and appends the proxy env to ~/.profile. Nothing needs root.

```bash
./setup-opencode-proxy.sh
```

Running as root instead writes system paths (/etc/systemd/system, /usr/local/bin, /etc/profile.d) — the same script, both modes. It is idempotent and self-healing, so re-running is safe.

What it does:

1. kills any orphaned node socks5 process squatting on :40000. That was a real outage: the healthcheck kept restarting it, and it stole the port from warp-svc
2. checks the WARP registration exists, re-registers if missing (self-heal)
3. installs oc-free-proxy.js + deps if absent
4. writes + starts the oc-free-proxy unit on :6446 (with ALL_PROXY pointed at the WARP socks)
5. installs warp-rotate.timer (IP rotation every ~20 min) and warp-heal.timer (daily guard), only if warp-cli is available
6. writes the opencode proxy env (OPENCODE_BASE_URL=http://127.0.0.1:6446/v1)

The script touches only the proxy and opencode. It will not configure 9router, pi, or anything else.

## WARP is optional

If warp-cli/warp-svc is not installed, the proxy still works with direct egress; rotation and heal-guard are skipped with a note. Install Cloudflare WARP if you want rotating IPs:

```bash
# Debian/Ubuntu
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-warp.list
sudo apt update && sudo apt install cloudflare-warp
```

## Rotation

warp-rotate.timer fires every 20 minutes. It deletes the WARP registration, registers a new one, and reconnects. The registration ID changes every cycle. The visible egress IP changes most of the time, but the free tier hands out a small pool, so the same IP can appear twice in a row. Don't read too much into a repeat.

## Auto-sync (free model discovery)

The proxy reads `free-models.json` next to it when present (built-in list is the fallback). `sync-models.sh` keeps that file fresh:

- fetches the upstream free-model list (`*-free`)
- **probes each candidate with a real chat** — only models that return 200 with a completion are kept (supervised: a model can be *listed* upstream but 401 on the anonymous tier, e.g. north-mini-code-free — probing skips it)
- writes only working models to free-models.json, restarts oc-free-proxy if the list changed
- runs daily via `sync-models.timer` (installed by the setup script)

Run manually anytime: `sudo sync-models.sh` (or `sync-models.sh` as a normal user).

## Verify

```bash
curl -s http://127.0.0.1:6446/health        # {"status":"ok"}
curl -s -x socks5h://127.0.0.1:40000 https://api.ipify.org   # 104.28.x.x with WARP
curl -s http://127.0.0.1:6446/v1/models     # free model list
```

## Files

- setup-opencode-proxy.sh — one-shot installer (sudo-free, idempotent, self-healing)
- oc-free-proxy.js — the OpenAI-compatible proxy (installed by the setup script)
