# opencode-proxy-rotator

Rotates the egress IP for OpenCode's traffic through Cloudflare WARP. One box, three pieces: oc-free-proxy on :6446 (the OpenAI-compatible surface opencode talks to), warp-svc on :40000 (the WARP SOCKS5), and a systemd timer that re-registers the WARP account every 20 minutes to get a fresh Cloudflare IP.

This repo exists because the previous design stopped working. That setup generated 30 WireGuard configs and rotated between them. Cloudflare accepted the registrations but refused the handshakes, all except one. So the script spent its time importing tunnels that never came up. The replacement throws away the WireGuard pool entirely and uses warp-cli, which is the tool Cloudflare ships for this.

## Install

Run setup-opencode-proxy.sh as root. It:

1. kills any orphaned node socks5 process squatting on :40000. That was a real outage: the healthcheck kept restarting it, and it stole the port from warp-svc
2. starts warp-svc and waits for it to bind :40000
3. writes the oc-free-proxy systemd unit and starts it on :6446
4. disables the dead wg-pool-rotate service so it never comes back
5. writes /etc/profile.d/opencode-proxy.sh so opencode sees the proxy

The script touches only the proxy and opencode. It will not configure 9router, pi, or anything else.

## Rotation

warp-rotate.timer fires every 20 minutes. It deletes the WARP registration, registers a new one, and reconnects. The registration ID changes every cycle. The visible egress IP changes most of the time, but the free tier hands out a small pool, so the same IP can appear twice in a row. Don't read too much into a repeat.

## Verify

```bash
curl -s http://127.0.0.1:6446/health        # {"status":"ok"}
curl -s -x socks5h://127.0.0.1:40000 https://api.ipify.org   # 104.28.x.x
curl -s http://127.0.0.1:6446/v1/models     # free model list
```
