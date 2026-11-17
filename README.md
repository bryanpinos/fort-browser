# Fort – Safe Home Browser

**A kids' web browser for iPad that only works through your home network, run on hardware you own.**

Fort is a browser for families who run their own network. Instead of another cloud filter and another subscription, it ties your kids' browsing to your home: your router's content filter, your rules, your hardware. No accounts, no subscription, no telemetry; nothing goes anywhere but to servers you run.

- **Fort on its own:** a filtered browser with a PIN-protected parent area: allowed and blocked sites, strict SafeSearch, favorites, tabs, and a friendly block page ("this one stays outside the fort"). Can be the iPad's default browser, so links from other apps get the same checks.
- **With the relay:** every page goes through your home, so your home filter applies at school, at a friend's house or on a hotspot. Each iPad has its own certificate from your family's own certificate authority, so a stolen password gets nobody in. If home can't be reached, Fort doesn't browse.
- **Home config:** change favorites, blocked sites and more on every iPad from home.
- **Page review:** a local AI reads the pages your kids visit and tells you about anything worrying.
- **Fort Chat:** a kids' chat helper on your own AI hardware (homework, stories, "what rock is this?"), with two safety models checking every message, reply, photo and search result. It fails closed.
- **Fort Parent:** your console for each kid's browsing and chats and the home config, signed in with passkeys.

## Get it
- **App Store:** *Fort – Safe Home Browser* (iPad)
- **TestFlight beta:** https://testflight.apple.com/join/BsRg4eQ2
- **Build from source:** see [Fort on its own](docs/fort-app.md#building)

## Guides
1. [How Fort fits together](docs/overview.md): architecture, data flows, security design
2. [Fort on its own](docs/fort-app.md): parent settings, Screen Time lockdown, default browser, config JSON
3. [The relay](docs/relay.md): certificates, Envoy, port forward, VLAN isolation (UniFi example)
4. [Home config](docs/home-config.md)
5. [Page review](docs/page-review.md)
6. [Fort Chat](docs/fort-chat.md)
7. [Fort Parent](docs/parent-console.md)

Start with Fort alone; add the relay when you want your home filter everywhere; add the rest if you run a local AI.

## In this repository
| Path | What |
|---|---|
| `Sources/`, `Tests/`, `project.yml` | The iPad app (Swift/SwiftUI around WKWebView; [XcodeGen](https://github.com/yonaskolb/XcodeGen) project) |
| `server/relay/` | The relay: Envoy template, compose files, home-config/ingest service, page-review worker, kids' search and page reader, certificate scripts |
| `server/chat-guard/` | The Kids Guard filter for Open WebUI, `configure.py`, the evaluation set and tests |
| `server/parent/` | Fort Parent, the parents' console |
| `docs/` | The guides |

## Privacy
Fort sends nothing to its developer. See the [privacy policy](https://github.com/bryanpinos/bryanpinos/blob/main/fort-privacy.md).

## Contributing and contact
Issues and pull requests welcome. Questions: fortsafebrowser@gmail.com.

## License
MIT. See [LICENSE](LICENSE).
