#!/usr/bin/env python3
"""Locks down a kids' Open WebUI (Fort Chat) and installs the Kids Guard.

    python3 configure.py --url http://127.0.0.1:3001 --key-file admin.key \\
        --model gemma-4-31b-it [--search-url http://HOST:8081/search] \\
        [--fetch-url http://HOST:8082/fetch] [--alert-webhook https://...] [--add-users]

Needs an admin API key (Admin Panel > Settings > General > Enable API Keys, then
Settings > Account > API Keys). Safe to run again: it sets everything to the
same state. What it does is listed in docs/fort-chat.md.
"""
import argparse, json, os, sys, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


class API:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/"), key

    def find(self, path):
        """GET that returns None for "not found" instead of stopping."""
        req = urllib.request.Request(self.url + path, headers={"Authorization": "Bearer " + self.key})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                return json.loads(data) if data else None
        except (urllib.error.HTTPError, ValueError):
            return None

    def __call__(self, path, body=None, method=None):
        req = urllib.request.Request(self.url + path, json.dumps(body).encode() if body is not None else None,
                                     {"Authorization": "Bearer " + self.key, "Content-Type": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            raise SystemExit(f"{method or ('POST' if body is not None else 'GET')} {path}: HTTP {e.code} {e.read().decode()[:200]}")


def step(msg):
    print(f"- {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--key-file", required=True, help="file holding an admin API key")
    ap.add_argument("--model", required=True, help="the chat model's id as Open WebUI lists it (e.g. gemma-4-31b-it)")
    ap.add_argument("--search-url", default="", help="kids' SearXNG search URL; omit to leave web search off")
    ap.add_argument("--fetch-url", default="", help="kids' page reader URL; omit to leave link reading off")
    ap.add_argument("--alert-webhook", default="", help="where 'child may need help' alerts go (e.g. a Home Assistant webhook)")
    ap.add_argument("--qwen-model", default="qwen3guard-gen-4b")
    ap.add_argument("--shield-model", default="shieldstral-1.0-3b")
    ap.add_argument("--add-users", action="store_true", help="add every non-admin account to the Kids group")
    a = ap.parse_args()
    api = API(a.url, open(a.key_file).read().strip())
    # Admin-only endpoint: a non-admin key gets an error here and nothing changes.
    api("/api/v1/auths/admin/config")

    step("instance: no sign-ups, new accounts wait for you, no notes/memories/channels, sign-in lasts a year")
    ac = api("/api/v1/auths/admin/config")
    # Two-step-verification settings can only be changed in a signed-in session, and
    # we don't change them: leave them out so an API key may save the rest.
    ac = {k: v for k, v in ac.items() if "MFA" not in k.upper() and "TOTP" not in k.upper()}
    ac.update(ENABLE_SIGNUP=False, DEFAULT_USER_ROLE="pending", ENABLE_NOTES=False, ENABLE_MEMORIES=False,
              ENABLE_CHANNELS=False, ENABLE_COMMUNITY_SHARING=False, ENABLE_USER_WEBHOOKS=False, JWT_EXPIRES_IN="52w")
    api("/api/v1/auths/admin/config", ac)

    step("what kids may do: chat, attach photos; no system prompts, tools, temporary chats, uploads of pages, voice calls")
    p = api("/api/v1/users/default/permissions")
    p["chat"].update(controls=False, valves=False, system_prompt=False, params=False, file_upload=True, web_upload=False,
                     share=False, call=False, multiple_models=False, temporary=False)
    p["chat"]["import"] = False
    p["features"].update(notes=False, channels=False, memories=False, calendar=False, automations=False, webhooks=False,
                         api_keys=False, direct_tool_servers=False, image_generation=False, code_interpreter=False,
                         web_search=bool(a.search_url))
    for section in ("workspace", "sharing"):
        p[section] = {k: False for k in p.get(section, {})}
    api("/api/v1/users/default/permissions", p)

    step("background tasks: titles only (no tags, follow-ups, autocomplete, search queries)")
    tc = api("/api/v1/tasks/config")
    tc.update(ENABLE_TAGS_GENERATION=False, ENABLE_SEARCH_QUERY_GENERATION=False, ENABLE_FOLLOW_UP_GENERATION=False,
              ENABLE_AUTOCOMPLETE_GENERATION=False, ENABLE_RETRIEVAL_QUERY_GENERATION=False)
    api("/api/v1/tasks/config/update", tc)

    step(f"models: only {a.model} from the model server; no arena model")
    oc = api("/openai/config")
    oc["OPENAI_API_CONFIGS"] = {"0": {"enable": True, "model_ids": [a.model], "prefix_id": "", "tags": []}}
    api("/openai/config/update", oc)
    ev = api("/api/v1/evaluations/config")
    if isinstance(ev, dict) and "ENABLE_EVALUATION_ARENA_MODELS" in ev:
        ev["ENABLE_EVALUATION_ARENA_MODELS"] = False
        api("/api/v1/evaluations/config", ev)

    step("web search: done by the guard (Open WebUI's own setting points at the same SearXNG, snippets only)")
    rc = api("/api/v1/retrieval/config")
    web = rc.get("web", {})
    web["ENABLE_WEB_SEARCH"] = bool(a.search_url)
    if a.search_url:
        for k, v in {"WEB_SEARCH_ENGINE": "searxng", "SEARXNG_QUERY_URL": a.search_url + "?q=<query>",
                     "BYPASS_WEB_SEARCH_WEB_LOADER": True, "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL": True}.items():
            if k in web:
                web[k] = v
    api("/api/v1/retrieval/config/update", {**rc, "web": web})

    step("Kids Guard: installed, on, and global (it checks every chat on this instance)")
    src = open(os.path.join(HERE, "kids_guard_filter.py")).read()
    meta = {"description": "Checks every message and reply with two local guard models. Fails closed."}
    existing = [f["id"] for f in api("/api/v1/functions/")]
    if "kids_guard" in existing:
        api("/api/v1/functions/id/kids_guard/update", {"id": "kids_guard", "name": "Kids Guard", "content": src, "meta": meta})
    else:
        api("/api/v1/functions/create", {"id": "kids_guard", "name": "Kids Guard", "content": src, "meta": meta})
    f = api("/api/v1/functions/id/kids_guard")
    if not f.get("is_active"):
        api("/api/v1/functions/id/kids_guard/toggle", {}, "POST")
    if not api("/api/v1/functions/id/kids_guard").get("is_global"):
        api("/api/v1/functions/id/kids_guard/toggle/global", {}, "POST")
    valves = api("/api/v1/functions/id/kids_guard/valves") or {}
    valves.update(chat_model=a.model, qwen_model=a.qwen_model, shield_model=a.shield_model,
                  search_url=a.search_url, fetch_url=a.fetch_url)
    if a.alert_webhook:
        valves["alert_webhook_url"] = a.alert_webhook
    api("/api/v1/functions/id/kids_guard/valves/update", valves)

    step("Kids group, and a 'Fort Chat' model only that group can use")
    groups = {g["name"]: g["id"] for g in api("/api/v1/groups/")}
    gid = groups.get("Kids") or api("/api/v1/groups/create", {"name": "Kids", "description": "Can use Fort Chat"})["id"]
    grant = [{"principal_type": "group", "principal_id": gid, "permission": "read"}]
    caps = {"vision": True, "file_upload": True, "web_search": bool(a.search_url)}
    fort = {"id": "fort-chat", "base_model_id": a.model, "name": "Fort Chat", "params": {}, "access_grants": grant, "is_active": True,
            "meta": {"description": "A friendly helper for homework, stories and questions.", "filterIds": ["kids_guard"], "capabilities": caps}}
    # Open WebUI also requires access to the base model; it stays hidden from the picker.
    base = {"id": a.model, "base_model_id": None, "name": f"{a.model} (base, hidden)", "params": {}, "access_grants": grant,
            "is_active": True, "meta": {"hidden": True, "description": "Base for Fort Chat."}}
    for m in (base, fort):
        found = api.find(f"/api/v1/models/model?id={m['id']}")
        api(f"/api/v1/models/model/update?id={m['id']}", m) if found and found.get("id") else api("/api/v1/models/create", m)
    cfg = api("/api/v1/configs/models")
    cfg["DEFAULT_MODELS"] = "fort-chat"
    api("/api/v1/configs/models", cfg)
    api("/api/models?refresh=true")

    if a.add_users:
        users = [u for u in api("/api/v1/users/").get("users", []) if u.get("role") == "user"]
        if users:
            api(f"/api/v1/groups/id/{gid}/users/add", {"user_ids": [u["id"] for u in users]})
        step(f"added to Kids: {', '.join(u['name'] for u in users) or 'nobody yet'}")
    print("Done. Turn 'Enable API Keys' off again unless Fort Parent uses this key.")


if __name__ == "__main__":
    main()
