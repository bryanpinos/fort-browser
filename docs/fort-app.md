# Fort on its own

Fort works without any server: install it, set a PIN, and it's a filtered browser. Everything here is in **Parent settings** (the gear icon).

## Install
- **App Store:** search for *Fort – Safe Home Browser* (iPad).
- **TestFlight beta:** https://testflight.apple.com/join/BsRg4eQ2
- **Build it yourself:** see [Building](#building).

## First setup
1. Open Fort, tap the gear, and set a **Parent PIN**.
2. **Sites:** add blocked sites (one per line; subdomains are included), or list allowed sites to allow *only* those. A fresh install starts with a small block list of adult and gambling sites.
3. **Force strict safe search** is on by default (Google, Bing, DuckDuckGo).
4. **Search with** picks where address-bar searches go: Google (the default), Bing, DuckDuckGo, or a custom engine (an https address with `%s` where the search words go, e.g. `https://search.example.com/search?q=%s`). Fort can only force strict safe search on the three built-in engines, so choose a custom one that filters results itself.
5. **Favorites:** one per line, address then name, e.g. `pbskids.org PBS Kids`. Kids can star their own too.
6. **Home page**: where the house button goes.
7. Tap **Save**.

## Lock down the iPad (Screen Time)
Fort can only protect what goes through it. In **Settings › Screen Time** on the kid's iPad (or from your device with Family Sharing):
- **Content & Privacy Restrictions › Allowed Apps & Features:** turn off **Safari** (and anything else that browses).
- **iTunes & App Store Purchases:** set **Installing Apps** and **Deleting Apps** to **Don't Allow**.
- **Content & Privacy Restrictions › App Store, Media, Web & Games › Apps:** set the limit to **16+** or **Allow All Apps**. Fort is rated 16+ on the App Store (any browser can reach the open web, and Apple rates for that), so a lower limit hides Fort. That's safe here: with app installs blocked, the age limit isn't what keeps other apps off the iPad.
- **Make Fort the default browser:** Settings › Apps › Default Apps › Browser App › Fort. Then links tapped in Messages, Mail or games open in Fort, with the same checks.

## Links to other apps
Some sites hand off to their own app, for example Roblox after you sign in or buy Robux (`roblox://…`). Fort opens only the apps you list under **Parent settings › Apps pages may open** (or `appLinks` in the [home config](home-config.md)), and asks first ("Open this in Roblox?"), so a page can't launch apps by itself. Any other app link shows "This page wants to open another app" instead of silently doing nothing. Fort never opens other browsers, Shortcuts, Settings or the App Store, even if listed. The name to list is the part of the link before `://`; the console's activity view shows refused app links, which is the easiest way to find it.

## Home Screen shortcuts
`fort://open?url=<address>` opens Fort straight to a site. In the **Shortcuts** app: new shortcut › **Open URLs** › `fort://open?url=pbskids.org` › **Add to Home Screen**.

## Configuration as JSON
Every setting is one JSON document (`GateConfig`). You can export it, paste it on another iPad (**Import / export**), fetch it from a URL, push it with an MDM (managed app config, key `config`, a JSON string), or serve it from your relay ([home config](home-config.md)).

| Field | Meaning |
|---|---|
| `denylist`, `allowlist` | Site names. Blocked wins over allowed; an empty allowlist allows everything else. |
| `enforceSafeSearch` | Strict mode on Google, Bing and DuckDuckGo. |
| `searchEngine` | Address-bar searches: `"google"` (or left out), `"bing"`, `"duckduckgo"`, or a custom `"https://…%s…"` address (no forced safe search). An invalid value means Google. |
| `appLinks` | Other apps a page may open, by link name: `["roblox"]`. Fort asks before opening one. Other browsers, Shortcuts, Settings and the App Store are never opened. Left out = none. |
| `homeURL` | The home page. |
| `favorites` | `[{"name": "PBS Kids", "url": "https://pbskids.org"}]` |
| `proxy` | The relay: `{"kind": "relay", "host": "relay.example.com", "port": 8443, "authToken": "…"}` ([guide](relay.md)). |
| `reviewPages` | Send page text home for review ([guide](page-review.md)). |
| `logEndpoint` | Optional URL that receives the activity log. |
| `probeURL`, `probeIntervalSeconds` | Without a relay: only browse while this URL on your network answers. |
| `parentPINHash` | SHA-256 of the PIN (hex). |

## Building
Requirements: Xcode 16.2 or later (developed with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen).
```sh
xcodegen generate
open Fort.xcodeproj    # set your team under Signing, then run on an iPad
xcodebuild test -scheme Fort -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```
`project.yml` is the source of truth (including entitlements); don't commit `Fort.xcodeproj`. The default-browser entitlement is granted per App ID by Apple; remove it from `project.yml` for your own builds unless your App ID has it.
