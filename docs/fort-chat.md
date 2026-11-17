# Fort Chat

A chat helper for kids, running on your own AI hardware: homework help, stories, "why is the sky blue?", "what kind of rock is this?" (with a photo). It's a **separate** [Open WebUI](https://openwebui.com/) just for the kids, with the **Kids Guard** filter checking everything that goes in and out.

## How the guard works
Two small safety models run next to the chat model and check:
- **every message a kid sends,** with both models; a message either fails is never shown to the chat model, and the kid gets a short, friendly decline;
- **every reply,** before any of it reaches the screen: text is released in checked batches, so unchecked words never appear, even briefly;
- **every photo** a kid attaches (Shieldstral can see images);
- **web search results and linked pages:** the guard does the searching and page reading itself, and drops anything that fails the check before the chat model sees it.

It **fails closed**: if a check can't run, the kid gets "the safety check isn't working", never an unchecked answer. It overwrites any system prompt, tools or features the chat page might send, so a kid can't switch them on.

A message that suggests a child may be in danger (self-harm, abuse, an adult asking for secrets, pictures or a meeting) gets a fixed, caring reply that points to a trusted adult and to 988, and can **alert your phone**.

| Model | Role |
|---|---|
| Your chat model, e.g. **Gemma 4 31B** | Answers. Also decides, with a one-word yes/no, whether a question needs a web search. |
| **Qwen3Guard-Gen-4B** (Alibaba) | Safety check: text messages and replies. |
| **Shieldstral 1.0 3B** (Mistral) | Safety check with a plain-English policy ("not right for a child aged 9 to 13?", "child in danger?"); also photos. |

## Limits
No filter is perfect. On our 68-message test set the two guards together caught every unsafe message with no false blocks, but that set is small and the thresholds were tuned on it; slow-drifting conversations aren't tested much. Chat titles are generated without the guard. Search answers about current events depend on the snippets found and can be wrong. Treat Fort Chat as a well-supervised helper, not a guarantee, and read your kids' chats now and then ([Fort Parent](parent-console.md) shows them). Run `server/chat-guard/eval/` with your own test messages before trusting it.

## What you need
- A machine with enough memory for the models: about 34 GB for Gemma 4 31B (8-bit) plus about 9 GB for the two guards, e.g. an Apple-silicon Mac with 64 GB or more, running [LM Studio](https://lmstudio.ai/) with "Serve on Local Network".
- Docker on that machine or another one, for the kids' Open WebUI.
- [The relay](relay.md) (with the `chat` profile for search and links) and a reverse proxy with HTTPS (e.g. Caddy) if the iPads should reach Fort Chat.

## 1. Models
In LM Studio, download the chat model and the two guards (search for `Qwen3Guard-Gen-4B` and `Shieldstral-1.0-3B`; GGUF Q8 builds work). **Load all three explicitly**, with their model keys as identifiers:
```sh
lms load gemma-4-31b-it --identifier gemma-4-31b-it --context-length 8192
lms load qwen3guard-gen-4b --identifier qwen3guard-gen-4b --context-length 8192
lms load shieldstral-1.0-3b --identifier shieldstral-1.0-3b --context-length 8192
```
Models loaded on demand can be evicted when another loads, which makes every message reload a 30 GB model; explicit loads stay. They don't survive an LM Studio restart, so run those three lines at login (a launchd agent on a Mac).

## 2. The kids' Open WebUI
```sh
cd server/chat-guard
printf 'WEBUI_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > .env && chmod 600 .env
docker compose up -d
```
It listens on `127.0.0.1:3001` only, so nobody else can claim the admin account. On that machine, open http://localhost:3001 and **create your admin account**.

Then, as admin: **Admin Panel › Settings › General › Enable API Keys** (save), and **Settings › Account › API Keys** › create a key. Save it to a file (`chmod 600`).

## 3. Search and page reading (optional)
Without these, Fort Chat answers only from what the chat model already knows. With them, the guard can look things up, the way a person would search before answering, and can read a page a kid pastes a link to. Both run in the relay's stack (the `chat` profile), so they reach the web through the same filtered network as the iPads:

| Service | What it is | Used for |
|---|---|---|
| `kids-search` (`fort-kids-search`) | [SearXNG](https://docs.searxng.org/), a self-hosted metasearch engine. It asks DuckDuckGo, Bing, Brave and Wikipedia and merges the results. No account or API key. | "Who won the game last night?", "how tall is Mount Everest?" |
| `kids-fetch` (`fort-kids-fetch`) | A small page reader (`server/relay/kids_fetch.py`). It fetches one page and returns its text. | "What does this page say?" with a link |

**How the guard uses them.** For each kid message, the chat model first answers a one-word yes/no: does this need a web search? If yes, the guard queries SearXNG with strict SafeSearch, checks each result's title and snippet with the safety models, and passes only the ones that pass (5 by default) to the chat model as sources. Links in a kid's message are fetched by kids-fetch, and the page text is checked the same way before the chat model sees it. A result or page that fails is dropped silently. Kids never talk to SearXNG or kids-fetch directly: the relay refuses private addresses, and only the guard knows where they are.

### SearXNG's settings
`server/relay/search/settings.yml` is mounted as SearXNG's configuration. It builds on SearXNG's defaults and changes:
- **engines:** only `duckduckgo`, `bing`, `brave` and `wikipedia`. Fewer engines means fewer odd sources and fewer engines blocking you for too many requests. Add others from [the engine list](https://docs.searxng.org/user/configured_engines.html) if you like.
- **`safe_search: 2`** (strict), and the guard asks for strict on every query too.
- **`formats: [json]`**, which the guard needs. SearXNG returns 403 to JSON requests without it.
- **`limiter: false`** and **`image_proxy: false`:** the limiter is for public instances and needs Redis; this one has a single client, the guard.

The secret key comes from `SEARXNG_SECRET` and the contact address (Wikipedia's API asks for one) from `CONTACT_EMAIL`, both in `.env`. The image is `searxng/searxng:latest`; update it with the rest of the stack (`docker compose pull && docker compose up -d`), since search engines change their pages and SearXNG follows.

### Set them up
1. In the relay's `.env`: add `chat` to `COMPOSE_PROFILES`, and set
   - `CONTACT_EMAIL`, shown to the sites the page reader visits and to Wikipedia;
   - `SEARXNG_SECRET`, from `openssl rand -hex 32`;
   - `FETCH_ALLOWED_CLIENTS`, the address of the machine running the kids' Open WebUI (comma-separated if several). kids-fetch refuses everyone else, and won't start without it.
   - Optionally `KIDS_SEARCH_PORT` / `KIDS_FETCH_PORT` (default 8081 / 8082).
2. `docker compose up -d`.
3. Test from the machine running Open WebUI:
   ```sh
   curl -s 'http://<relay host>:8081/search?q=volcano&format=json&safesearch=2' | python3 -m json.tool | head -20
   curl -s 'http://<relay host>:8082/fetch?url=https://en.wikipedia.org/wiki/Volcano' | head -c 300
   ```
   With the VLAN overlay, use `http://<KIDS_SEARCH_IP>:8080/...` and `http://<KIDS_FETCH_IP>:8080/...`, and your firewall must let that machine reach those two addresses on TCP 8080.

**With the VLAN overlay** (recommended), kids-search and kids-fetch get their own addresses on the kids' VLAN and no host ports, so your gateway's kids' content filter and SafeSearch DNS apply to every search engine request and page they fetch. **Without it,** they publish ports 8081 and 8082 on the Docker host: don't forward those from the internet. kids-fetch only answers `FETCH_ALLOWED_CLIENTS`, but SearXNG answers anyone who can reach it.

### What kids-fetch refuses
Only `http`/`https` addresses whose every DNS answer is a public address (no LAN, loopback or link-local, so a link can't be used to probe your network), at most 3 redirects (each checked the same way), HTML or plain text only, at most 2 MB downloaded, and at most 6,000 characters of text returned.

### If search doesn't work
- **The guard answers but never cites anything:** check the two `curl` tests above first. If they work, the chat model decided no search was needed, or every result failed the check. Errors reaching search or the page reader show in the Open WebUI log (`docker compose logs` in `server/chat-guard`).
- **`curl` gets 403:** `json` is missing from `formats` in `settings.yml`.
- **Empty `results`:** an engine is blocking you (SearXNG's log, `docker logs fort-kids-search`, says which), or your content filter is blocking the engine itself. Allow the engines' domains in the kids' filter policy.
- **kids-fetch answers 403:** the calling machine isn't in `FETCH_ALLOWED_CLIENTS`. With Docker Desktop or OrbStack on a Mac, the request may come from a different address than you'd expect: the kids-fetch log (`docker logs fort-kids-fetch`) prints the refused address.

## 4. Lock it down and install the guard
```sh
python3 configure.py --url http://127.0.0.1:3001 --key-file admin.key --model gemma-4-31b-it \
  --search-url http://<relay host>:8081/search --fetch-url http://<relay host>:8082/fetch \
  --alert-webhook https://ha.example.com/api/webhook/<id>
```
(With the VLAN overlay, use `http://<KIDS_SEARCH_IP>:8080/search` and `http://<KIDS_FETCH_IP>:8080/fetch` instead.) It's safe to run again. It turns off sign-ups (new accounts wait for you), notes, memories, channels, temporary chats (you couldn't review them), page uploads, voice calls, system prompts and chat controls; limits the model list to your chat model; installs the guard **for every chat on this instance**; creates a **Kids** group and a **Fort Chat** model only that group can use; and makes sign-ins last a year. Leave out `--search-url` / `--fetch-url` to keep those off.

**Alerts:** any URL that accepts a JSON POST `{"kid": "...", "message": "..."}`. In Home Assistant, a webhook-triggered automation:
```yaml
alias: "Fort Chat: child may need help"
mode: parallel
triggers:
  - trigger: webhook
    webhook_id: <a long random id>
    allowed_methods: [POST]
    local_only: true
actions:
  - action: notify.notify
    data:
      title: "Check in with {{ trigger.json.kid }}"
      message: "{{ trigger.json.message }}"
```

## 5. Accounts
**Admin Panel › Users › +** for each kid (role *user*), then run `configure.py … --add-users` (or add them to the **Kids** group by hand). Their sign-in lasts a year; the relay certificate is what really keeps others out.

## 6. Reaching it from Fort
1. **Reverse proxy:** serve the kids' Open WebUI on its own HTTPS name, e.g. `chat.example.com`, bound to an address the proxy can reach (change the compose `ports` line). In that proxy, **refuse every other site to requests from the relay** (example: [examples/Caddyfile](examples/Caddyfile)): the relay can't see which site is asked for inside an encrypted tunnel, so this is what keeps the kids to Fort Chat.
2. **Relay:** set `KIDS_CHAT_HOST=chat.example.com` and `KIDS_CHAT_UPSTREAM_IP` (the proxy's address) in its `.env`, `python3 render.py`, restart the relay. With the VLAN overlay, also allow the kids' VLAN to reach the proxy on TCP 443. No public DNS record is needed: the relay connects to that fixed address itself.
3. **Fort:** add it as a favorite from [home config](home-config.md), or make a Home Screen icon: `fort://open?url=chat.example.com` in a Shortcut.
