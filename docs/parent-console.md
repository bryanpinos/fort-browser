# Fort Parent

Your console: each kid's browsing (visits, blocks, page-review flags) and Fort Chat conversations, whether Fort is their default browser and which build they run, and an editor for the [home config](home-config.md) that keeps every earlier version. **Sign-in is passkeys only** (Face ID / Touch ID, synced by iCloud Keychain). Needs [the relay](relay.md); Fort Chat is optional.

## Set up
```sh
cd server/parent
cp .env.example .env && chmod 600 .env    # then edit
docker compose up -d --build
```
In `.env`:
- `RP_ID` and `ORIGIN`: the console's own HTTPS name, e.g. `parent.example.com`. **Passkeys are tied to this name**, so pick it once.
- `RELAY_DIR`: the relay stack folder (the console reads `review/` and edits `config/`).
- `KIDS`: one entry per kid: an id, a display name, the device ID in their relay certificate, and their Fort Chat user name.
- Optional `OWUI_URL` + `OWUI_KEY` (a Fort Chat admin API key) to show chats, and `HA_ORIGIN` to show the console inside Home Assistant.

## Reverse proxy
Passkeys need HTTPS on a real name. Point your proxy at the console's port (`PARENT_PORT`, 8094) and **refuse your kids' network**: [examples/Caddyfile](examples/Caddyfile). The name only has to resolve where you'll use it (home, or over your VPN); it can point at a private address.

## Your first passkey
```sh
docker exec fort-parent python /app/app.py setup-code
```
prints a one-time link (valid 30 minutes, one passkey). **Treat it like a key to your kids' data:** don't paste it into chats or tickets; send it to your own phone privately (or run the command from a terminal on that device). Open it, name the passkey, and Face ID saves it to your iCloud Keychain, so your other Apple devices can sign in too. Run the command again to add another passkey, or to recover if you ever lose all of them.

## In Home Assistant
Add a **Webpage** dashboard pointing at the console's address and set `HA_ORIGIN` to your Home Assistant address. Browsers don't allow passkey prompts inside another site's frame, so sign in once in a normal tab; the panel then uses that session (30 days).
