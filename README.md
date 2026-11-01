# Hearth

**A kids' browser that only works through your home network.**

Hearth is an open-source iOS/iPadOS browser for parents who already run their own
network: a UniFi/pfSense/Firewalla gateway, a Tailscale or WireGuard tunnel, a
NextDNS/Pi-hole profile. Instead of shipping yet another cloud filter and a
subscription, Hearth locks the browser to *your* infrastructure:

- **Fail-closed gate.** The browser only loads pages while a parent-controlled
  URL on your tailnet answers. VPN off → blank screen with a "turn on Tailscale" button.
- **Proxy pin.** Every byte of page traffic can be forced through a proxy at home
  (`WKWebsiteDataStore.proxyConfigurations`), so your gateway's content filter,
  DNS rules and logs apply wherever the iPad is.
- **Allow/deny lists** enforced on navigation *and* compiled into WebKit's
  content blocker so blocked hosts can't load as sub-resources either.
- **Strict safe search** re-applied on every Google/Bing/DDG navigation.
- **Activity log** kept on-device, optionally batched to an endpoint you run.
- **No account, no cloud, no telemetry.** Config is a JSON blob you paste, fetch
  from a URL on your NAS, or push via MDM AppConfig.

Pair it with Screen Time (hide Safari, block app installs, set a passcode) and
Hearth is the only door to the web on the device.

> Status: early skeleton. It runs, but expect rough edges. Issues and PRs welcome.

## Why not just use …

| | Hearth | Cloud "safe browsers" | DNS filtering alone |
|---|---|---|---|
| Works away from home | ✅ via your VPN | ✅ | only on your Wi‑Fi (unless DoH profile) |
| Who holds the logs | you | the vendor | you / the DNS vendor |
| Subscription | none | $30–60/yr | free–$20/yr |
| Enforced by | your network | their cloud | DNS only |

## Requirements

- Xcode 16+, iOS/iPadOS 17+
- An Apple Developer account (free works for 7-day installs; paid for 1-year)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Something at home the iPad can reach only over your VPN (the `server/` folder
  gives you a probe, a proxy and a log collector in one `docker compose up`)

## Build

```bash
git clone https://github.com/<you>/hearth
cd hearth
# edit project.yml: bundleIdPrefix and DEVELOPMENT_TEAM
xcodegen generate
open Hearth.xcodeproj
```

Select your team under Signing & Capabilities, pick the iPad, Run.

## Home side

```bash
cd server
# edit probe/hearth.json: replace 100.0.0.1 with the NAS's Tailscale IP
docker compose up -d
```

| Service | Port | Purpose |
|---|---|---|
| probe | 8088 | `GET /ok` → 200; also serves `/hearth.json` for one-URL device setup |
| proxy | 3128 | Squid HTTP CONNECT proxy; only accepts tailnet/LAN clients |
| logs  | 8089 | `POST /log` collector, `GET /` to eyeball the last 200 entries |

Bind the ports to the host's tailnet address (`100.x.y.z:8088:80`) if the box
also sits on a network you don't fully trust.

## First-run on the iPad

1. Install Tailscale, sign the iPad into your tailnet (a tag-only node with
   an ACL that reaches just the NAS is ideal).
2. Open Hearth → gear icon → **Import / export → Config URL** →
   `http://<nas-tailnet-ip>:8088/hearth.json` → Fetch → Save.
3. Set a parent PIN.
4. Screen Time: Content & Privacy → Allowed Apps → Safari **off**;
   iTunes & App Store Purchases → Installing Apps **Don't Allow**, Deleting Apps
   **Don't Allow**; set a Screen Time passcode.

## Config reference

```jsonc
{
  "probeURL": "http://100.0.0.1:8088/ok",   // null disables the gate
  "probeIntervalSeconds": 15,
  "proxy": { "kind": "http", "host": "100.0.0.1", "port": 3128 }, // or "socks5"; null = direct
  "allowlist": [],                           // non-empty = only these hosts (+subdomains)
  "denylist": ["tiktok.com"],                // always blocked, wins over allowlist
  "enforceSafeSearch": true,
  "homeURL": "https://www.wikipedia.org",
  "logEndpoint": "http://100.0.0.1:8089/log", // null = on-device only
  "parentPINHash": null                       // sha256 hex; set from the app
}
```

MDM users: push the same JSON as a string under the `config` key in managed
app configuration; the in-app settings become read-only.

## What Hearth does *not* do

- It can't filter inside other apps. Screen Time's web filter covers WebKit
  views in other apps; your DNS filter covers everything else.
- It can't stop a kid who has the Screen Time passcode. Keep it off the iPad.
- Signing: a Developer-signed build expires yearly (7 days on a free account).
  Re-run from Xcode before it lapses, or ship via TestFlight / the App Store.

## Roadmap

- [ ] QR-code config import
- [ ] Per-kid profiles / time windows
- [ ] Family Controls entitlement so Hearth can shield Safari and other apps itself
- [ ] Default-browser entitlement
- [ ] Hardened App Store build with a reviewer-friendly demo config
- [ ] macOS (Chromium-based) sibling

## License

MIT — see [LICENSE](LICENSE).
