# App Store listing

The text for App Store Connect, kept here so later versions start from it. Screenshots come from `Tests/FortUITests/AppStoreScreenshots.swift` (instructions at the top of that file), on the iPad Pro 13-inch simulator (2064 × 2752).

## Name (30)
Fort – Safe Home Browser

## Subtitle (30)
A kids' browser, run from home

## Promotional text (170)
A web browser for kids where the rules live at home: your blocked sites, your content filter, strict SafeSearch. No accounts, no subscription, nothing sent to us.

## Description (4000)
Fort is a web browser for kids, built for parents who'd rather set the rules themselves than hand them to another company.

Think of it as a blanket fort for the web: the kids' own space, with you deciding what gets in.

ON ITS OWN
• Block sites, or allow only the sites you list.
• Strict SafeSearch on Google, Bing and DuckDuckGo, every time. Kids can't turn it off.
• Choose the search engine.
• A start page of favorites you pick, and kids can star their own.
• Tabs, find on page, and a friendly "this one stays outside the fort" page instead of scary errors.
• A PIN-protected area for grown-ups.

WITH YOUR HOME NETWORK (optional, for technical parents)
Fort can send every page through a small relay you run at home, so your home network's content filter (for example UniFi, Pi-hole or NextDNS) applies wherever the iPad is. Each iPad carries its own certificate, and if Fort can't reach home, it doesn't browse: it never quietly falls back to an unfiltered connection. From home you can also:
• change settings on every iPad at once, or per child;
• see browsing activity in the Fort Parent console;
• have a local AI model on your own hardware review pages and alert you to anything worrying.
The relay and console are free and open source, with step-by-step guides.

WORKS WITH SCREEN TIME
Hide Safari and block app installs with Screen Time, and Fort is the browser your kids use. Fort can also be set as the default browser, so links from other apps open in Fort.

PRIVATE BY DESIGN
No account, no subscription, no ads, no analytics. Fort sends nothing to its developer. Anything it sends goes only to servers you set up.

Open source (MIT): github.com/bryanpinos/fort-browser

## Keywords (100)
parental control,kids,child,safe,filter,family,web,homeschool,safesearch,school,block,internet

## URLs
- Support URL: https://github.com/bryanpinos/fort-browser
- Marketing URL: https://github.com/bryanpinos/fort-browser
- Privacy Policy URL: https://github.com/bryanpinos/bryanpinos/blob/main/fort-privacy.md

## Other fields
- Primary category: Utilities. Secondary: Education.
- Copyright: 2026 Bryan Pinos
- Price: Free. Availability: all countries.
- App Privacy: Data Not Collected.
- Age rating: answer the questionnaire honestly. A browser has **unrestricted web access** (Fort with no setup blocks only a starter list), which Apple rates at the top age band, like Safari and Chrome. Don't choose the Kids category: browsers can't meet its rules on external links.
- Sign-in required: no.

## App Review notes
Fort is a web browser for children, with parental controls. It needs no account and no server: with no setup it works as a filtered browser, which is how it opens for review.

To try the parental controls: tap the gear (top right). No PIN is set on a fresh install, so settings open directly. Under Sites, add a blocked site (e.g. example.com), tap Save, then type that address: Fort shows its block page instead of the site. A Parent PIN can be set in the same screen.

Optional home features (a relay the parent runs on their own network, using a client certificate the parent issues) need the parent's own server, so they can't be used without one. With them set up, Fort only browses through the parent's home network and shows "Fort works from home" when it can't reach it. Setup guides: https://github.com/bryanpinos/fort-browser

The app has the com.apple.developer.web-browser entitlement (granted 2026-11-16) so parents can make it the default browser.
