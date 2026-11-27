# Screen Time blocking Safari makes canOpenURL fail for https, even with another default browser

**Not filed yet.** File in **Feedback Assistant** → *iOS & iPadOS* → *Screen Time*
(if there's no Screen Time area, use *Safari and Web Technologies* or
*Something else is not working as expected*). Paste the text below the line.
Attach a sysdiagnose from the affected iPad taken right after reproducing it,
or the log excerpts below. Don't attach the full `.logarchive` files: they
hold a lot of unrelated personal data.

---

**Title:** With Safari blocked by Screen Time, canOpenURL returns false for https URLs even though a third-party default browser is set

**Area:** Screen Time (Content & Privacy Restrictions › Allowed Apps & Features), LaunchServices / UIApplication canOpenURL, default browser

**Type:** Incorrect/Unexpected Behavior

**Summary**
On a child's iPad managed by Family Sharing Screen Time, turning off **Safari**
under *Content & Privacy Restrictions › Allowed Apps & Features* makes
`UIApplication.canOpenURL(_:)` return `false` for ordinary `https://` URLs in
third-party apps, even though a third-party browser (with the
`com.apple.developer.web-browser` entitlement) is set as the default browser
and is not restricted. Apps that check `canOpenURL` before calling
`open(_:)`, which is common, then silently do nothing, so the child can't
follow any web link out of those apps.

With Safari allowed, the same app, URL and default browser work: iOS routes
the link to the default browser, not to Safari. So the restriction meant to
hide Safari also stops links reaching the browser the parent chose instead.

Parents who use a parental-control browser as the default have exactly this
setup (Safari off, their browser as default), so for them every app's "open
in browser" link breaks.

**Environment**
- Two iPad (A16) (iPad15,7), both iPadOS 27.2.1 (24B156), child accounts in
  the same Family Sharing group with Screen Time managed by a parent.
- Default browser on both: a third-party browser from the App Store with the
  default-browser entitlement (Fort – Safe Home Browser, `dev.pinos.fort`,
  version 1.0 (7)). Settings › Apps › Default Apps › Browser App shows it on both.
- The app following the link: Roblox 2.748.1526 (`com.roblox.robloxmobile`),
  from its in-app Robux store (a WKWebView). Its link-out is an `https://` URL.
- The only relevant Screen Time difference between the two iPads:
  Safari allowed on iPad A, Safari blocked on iPad B.

**Steps to reproduce**
1. On an iPad with a child account, set a third-party browser as the default
   browser (Settings › Apps › Default Apps › Browser App).
2. In Screen Time › Content & Privacy Restrictions › Allowed Apps & Features,
   turn **Safari** off.
3. In any app that calls `canOpenURL` before `open` for an `https://` link,
   follow a web link. (Seen with Roblox's Robux store; a two-line test app
   calling `UIApplication.shared.canOpenURL(URL(string: "https://example.com")!)`
   should show the same.)

**Expected**
`canOpenURL` returns `true`, and `open` routes the link to the default
browser, as it does when Safari is allowed.

**Actual**
`canOpenURL` returns `false`. The app never calls `open`, no open request
reaches SpringBoard, and nothing happens on screen.

**Evidence** (from `log collect`, private data redacted by the system)

iPad B (Safari blocked), six taps, each one:
```
20:35:53.970 Roblox [com.apple.WebKit:Loading] NavigationState::decidePolicyForNavigationAction: Client responded with policy 0
20:35:53.972 Roblox (UIKitCore) -canOpenURL: failed for URL: "<private>" - error: "<private>"
```
No `FBSystemService ... Received request to open` from Roblox anywhere in the capture.
Screen Time at the time: `ScreenTimeAgent ... Updated allowed apps data: ... deny flags - ... Safari:1`

iPad A (Safari allowed), same app version, same button:
```
20:53:19.907 Roblox [com.apple.WebKit:Loading] NavigationState::decidePolicyForNavigationAction: Client responded with policy 0
20:53:19.910 lsd [com.apple.launchservices:open] pid N/Roblox requests to open URL with scheme <private>
20:53:19.918 SpringBoard [com.apple.FrontBoard:Common] [FBSystemService] Received request to open "dev.pinos.fort" with url "https:<private>" from lsd on behalf of Roblox
```
Screen Time at the time: `... deny flags - ... Safari:0`

The link goes to the third-party default browser when Safari is allowed, so
the URL is an ordinary https URL and the default browser is registered
correctly. Only the Safari restriction differs.

**Impact**
Parents can't hide Safari and still have links from other apps open in the
browser they chose. The workarounds are to leave Safari allowed (defeating
the point of a parental-control browser) or to accept that links from apps
silently fail. The second looks like a broken app to the child and to the app's
developer.

**Suggested fix**
When Safari is restricted, `canOpenURL` and `open` for `http`/`https` should
resolve to the user's chosen default browser if that browser is not
restricted, the same as when Safari is allowed.
