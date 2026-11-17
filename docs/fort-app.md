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
4. **Favorites:** one per line, address then name, e.g. `pbskids.org PBS Kids`. Kids can star their own too.
5. **Home page**: where the house button goes.
6. Tap **Save**.

## Lock down the iPad (Screen Time)
Fort can only protect what goes through it. In **Settings › Screen Time** on the kid's iPad (or from your device with Family Sharing):
- **Content & Privacy Restrictions › Allowed Apps & Features:** turn off **Safari** (and anything else that browses).
- **iTunes & App Store Purchases:** set **Installing Apps** and **Deleting Apps** to **Don't Allow**.
- **Make Fort the default browser:** Settings › Apps › Default Apps › Browser App › Fort. Then links tapped in Messages, Mail or games open in Fort, with the same checks.

## Home Screen shortcuts
`fort://open?url=<address>` opens Fort straight to a site. In the **Shortcuts** app: new shortcut › **Open URLs** › `fort://open?url=pbskids.org` › **Add to Home Screen**.

## Configuration as JSON
Every setting is one JSON document (`GateConfig`). You can export it, paste it on another iPad (**Import / export**), fetch it from a URL, push it with an MDM (managed app config, key `config`, a JSON string), or serve it from your relay ([home config](home-config.md)).

| Field | Meaning |
|---|---|
| `denylist`, `allowlist` | Site names. Blocked wins over allowed; an empty allowlist allows everything else. |
| `enforceSafeSearch` | Strict mode on Google, Bing and DuckDuckGo. |
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
