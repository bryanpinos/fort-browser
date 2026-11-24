# Home config

Change settings on every iPad from home: favorites, blocked and allowed sites, the home page, the search engine, apps pages may open, page review, SafeSearch, even the parent PIN. Needs [the relay](relay.md).

## How it works
- The relay serves `config/fort.json` (every iPad) with `config/devices/<device-id>.json` layered on top (one iPad; its fields replace `fort.json`'s).
- Fort fetches it when it connects to home and every 15 minutes after.
- Fields set from home **replace** the iPad's own values, and Parent settings shows them as *managed from home*; local edits to them don't stick, even with the PIN. Fields you leave out stay as each iPad has them. An MDM-pushed config still wins over both.
- A field you remove from the files goes back to the iPad's own value at the next fetch.
- **It can never change the relay connection** (`proxy` is always ignored), so a bad file can't cut an iPad off from home.
- **Invalid files are refused** (broken JSON, wrong types, a home page or favorite that isn't an http(s) address): the relay answers with an error and the iPads keep their last good config.
- One exception: an unrecognized `searchEngine` doesn't refuse the file. That iPad searches with Google instead, so a typo never stops searching.

## Editing it
The easy way is [Fort Parent](parent-console.md)'s Settings page, which validates and keeps every earlier version. By hand:
```json
{
  "reviewPages": true,
  "searchEngine": "duckduckgo",
  "favorites": [
    {"name": "PBS Kids", "url": "https://pbskids.org"},
    {"name": "Fort Chat", "url": "https://chat.example.com"}
  ],
  "denylist": ["roblox.com"]
}
```
Save as `server/relay/config/fort.json`; for one iPad, `config/devices/ava-ipad.json`. Fields: see [the field table](fort-app.md#configuration-as-json). `parentPINHash` is the SHA-256 of the PIN in hex (`printf 1234 | shasum -a 256`).

To see exactly what an iPad gets:
```sh
docker exec fort-relay-ingest python3 -c "import urllib.request as u; r=u.Request('http://127.0.0.1:8081/fort/config'); r.add_header('x-fort-device','spiffe://example.com/fort/device/ava-ipad'); print(u.urlopen(r).read().decode())"
```
