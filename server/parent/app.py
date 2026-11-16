"""Fort Parent: the parents' console for Fort.

Shows each kid's browsing (from the relay's review database) and Fort Chat
conversations (from the kids' Open WebUI), and edits the home config the relay
serves to the iPads (config/fort.json + config/devices/<device>.json), behind
passkey sign-in. Runs on the NAS; Caddy serves it as https://parent.example.com and
refuses the kids' VLAN.

Sign-in: passkeys only (WebAuthn). The first passkey is added with a one-time
setup code: `docker exec fort-parent python /app/app.py setup-code`.
"""
import hashlib, hmac, json, os, re, secrets, sqlite3, sys, time, urllib.request
from datetime import datetime, timedelta, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import webauthn
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (AuthenticatorSelectionCriteria, PublicKeyCredentialDescriptor,
                                      ResidentKeyRequirement, UserVerificationRequirement)

RP_ID = os.environ.get("RP_ID", "parent.example.com")
ORIGIN = os.environ.get("ORIGIN", "https://parent.example.com")
DATA = os.environ.get("DATA_DB", "/data/parent.db")
REVIEW_DB = os.environ.get("REVIEW_DB", "/review/review.db")
OWUI_URL = os.environ.get("OWUI_URL", "http://192.168.1.20:3001").rstrip("/")
OWUI_KEY = os.environ.get("OWUI_KEY", "")
KIDS = json.loads(os.environ.get("KIDS", "[]"))  # [{"id","name","device","chat_user"}]
PORT = int(os.environ.get("PORT", "8080"))
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/homeconfig")
HISTORY_KEEP = 100
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
SESSION_DAYS = 30
COOKIE = "fp_session"

SCHEMA = """
CREATE TABLE IF NOT EXISTS credentials (id TEXT PRIMARY KEY, public_key TEXT NOT NULL, sign_count INTEGER NOT NULL,
    name TEXT, created TEXT NOT NULL, last_used TEXT);
CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, expires REAL NOT NULL, created TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS setup_codes (code_hash TEXT PRIMARY KEY, expires REAL NOT NULL);
CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY, challenge TEXT NOT NULL, kind TEXT NOT NULL, expires REAL NOT NULL);
"""


def db():
    conn = sqlite3.connect(DATA, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def new_setup_code(minutes=30):
    code = secrets.token_urlsafe(24)
    with db() as c:
        c.execute("DELETE FROM setup_codes WHERE expires < ?", (time.time(),))
        c.execute("INSERT INTO setup_codes VALUES (?, ?)", (sha(code), time.time() + minutes * 60))
    return code


def setup_code_valid(code, consume=False):
    if not code:
        return False
    with db() as c:
        row = c.execute("SELECT 1 FROM setup_codes WHERE code_hash=? AND expires>?", (sha(code), time.time())).fetchone()
        if row and consume:
            c.execute("DELETE FROM setup_codes WHERE code_hash=?", (sha(code),))
    return bool(row)


def save_challenge(kind, challenge):
    cid = secrets.token_urlsafe(16)
    with db() as c:
        c.execute("DELETE FROM challenges WHERE expires < ?", (time.time(),))
        c.execute("INSERT INTO challenges VALUES (?,?,?,?)", (cid, bytes_to_base64url(challenge), kind, time.time() + 300))
    return cid


def take_challenge(cid, kind):
    with db() as c:
        row = c.execute("SELECT challenge FROM challenges WHERE id=? AND kind=? AND expires>?", (cid, kind, time.time())).fetchone()
        c.execute("DELETE FROM challenges WHERE id=?", (cid,))
    return base64url_to_bytes(row["challenge"]) if row else None


def new_session():
    token = secrets.token_urlsafe(32)
    with db() as c:
        c.execute("DELETE FROM sessions WHERE expires < ?", (time.time(),))
        c.execute("INSERT INTO sessions VALUES (?,?,?)", (sha(token), time.time() + SESSION_DAYS * 86400, now_iso()))
    return token


def session_valid(token):
    if not token:
        return False
    with db() as c:
        return bool(c.execute("SELECT 1 FROM sessions WHERE token_hash=? AND expires>?", (sha(token), time.time())).fetchone())


def end_session(token):
    with db() as c:
        c.execute("DELETE FROM sessions WHERE token_hash=?", (sha(token or ""),))


# ---- data -----------------------------------------------------------------

def kid(kid_id):
    return next((k for k in KIDS if k["id"] == kid_id), None)


def review_rows(sql, args=()):
    conn = sqlite3.connect(f"file:{REVIEW_DB}?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]
    finally:
        conn.close()


def since(days):
    return (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S")


def owui(path):
    req = urllib.request.Request(OWUI_URL + path, headers={"Authorization": "Bearer " + OWUI_KEY})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


_chat_users = {}


def chat_user_id(k):
    if k["chat_user"] not in _chat_users:
        users = owui("/api/v1/users/").get("users", [])
        for u in users:
            _chat_users[u["name"]] = u["id"]
    return _chat_users.get(k["chat_user"])


def kids_summary():
    out = []
    today, week = since(1), since(7)
    for k in KIDS:
        dev = k["device"]
        counts = review_rows("""SELECT
              SUM(kind='nav' AND ts>=?) AS visits_24h,
              SUM(kind='nav' AND allowed=0 AND ts>=?) AS blocked_24h,
              SUM(kind='nav' AND ts>=?) AS visits_7d,
              SUM(concern>=2 AND ts>=?) AS flagged_7d,
              MAX(ts) AS last_seen
            FROM events WHERE device=?""", (today, today, week, week, dev))[0]
        try:
            uid = chat_user_id(k)
            chats = owui(f"/api/v1/chats/list/user/{uid}?page=1") if uid else []
            chat_info = {"chats": len(chats), "last_chat": max((c.get("updated_at") or 0 for c in chats), default=None)}
        except Exception as e:
            chat_info = {"chats": None, "chat_error": type(e).__name__}
        out.append({"id": k["id"], "name": k["name"], **{x: counts[x] or 0 for x in ("visits_24h", "blocked_24h", "visits_7d", "flagged_7d")},
                    "last_seen": counts["last_seen"], **chat_info})
    return out


def browsing(k, days):
    return review_rows("""SELECT ts, kind, url, host, title, allowed, reason, status, category, concern, summary
                          FROM events WHERE device=? AND ts>=? ORDER BY ts DESC LIMIT 1000""", (k["device"], since(days)))


def chats(k):
    uid = chat_user_id(k)
    return owui(f"/api/v1/chats/list/user/{uid}?page=1") if uid else []


def chat_detail(k, chat_id):
    if not re.fullmatch(r"[A-Za-z0-9-]{8,64}", chat_id):
        return None
    c = owui(f"/api/v1/chats/{chat_id}")
    if not c or c.get("user_id") != chat_user_id(k):
        return None  # only this kid's chats
    hist = (c.get("chat") or {}).get("history", {})
    msgs, cur = [], hist.get("currentId")
    by_id = hist.get("messages", {})
    while cur and cur in by_id:  # the visible branch, newest last
        m = by_id[cur]
        content = m.get("content")
        if isinstance(content, list):
            content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
        msgs.append({"role": m.get("role"), "content": content or "", "timestamp": m.get("timestamp"),
                     "images": sum(1 for f in m.get("files") or [] if (f.get("type") == "image"))})
        cur = m.get("parentId")
    return {"title": c.get("title"), "updated_at": c.get("updated_at"), "messages": list(reversed(msgs))}


# ---- home config (control plane) ------------------------------------------
# Fields the console manages. Anything else (notably the relay connection) is
# refused, so a save can never cut an iPad off from home.
HOST = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def _web_url(v):
    if not isinstance(v, str):
        return False
    u = urlsplit(v.strip())
    return u.scheme in ("http", "https") and bool(u.hostname) and HOST.match(u.hostname.lower()) is not None


def _host_list(v):
    return isinstance(v, list) and len(v) <= 500 and all(isinstance(h, str) and HOST.match(h) for h in v)


VALIDATORS = {
    "favorites": lambda v: isinstance(v, list) and len(v) <= 24 and all(
        isinstance(f, dict) and set(f) == {"name", "url"} and isinstance(f["name"], str) and 0 < len(f["name"].strip()) <= 40
        and _web_url(f["url"]) for f in v),
    "denylist": _host_list,
    "allowlist": _host_list,
    "homeURL": _web_url,
    "enforceSafeSearch": lambda v: isinstance(v, bool),
    "reviewPages": lambda v: isinstance(v, bool),
    "parentPINHash": lambda v: isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) is not None,
}


def validate_config(data):
    """Returns a list of problems (empty if it's fine to save)."""
    if not isinstance(data, dict):
        return ["Settings must be a set of fields."]
    problems = [f"\"{k}\" can't be set here." for k in data if k not in VALIDATORS]
    problems += [f"\"{k}\" doesn't look right." for k, v in data.items() if k in VALIDATORS and not VALIDATORS[k](v)]
    return problems


def config_path(scope):
    if scope == "everyone":
        return os.path.join(CONFIG_DIR, "fort.json")
    k = kid(scope)
    return os.path.join(CONFIG_DIR, "devices", k["device"] + ".json") if k else None


def read_config(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}


def history_dir():
    return os.path.join(CONFIG_DIR, "history")


def write_config(path, data):
    """Archives the current file, then replaces it atomically (so the relay
    never serves half a file). An empty set of fields removes the file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.makedirs(history_dir(), exist_ok=True)
    name = os.path.basename(path)
    if os.path.exists(path):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        with open(path) as src, open(os.path.join(history_dir(), f"{name}.{stamp}"), "w") as dst:
            dst.write(src.read())
        old = sorted(x for x in os.listdir(history_dir()) if x.startswith(name + "."))
        for x in old[:-HISTORY_KEEP]:
            os.remove(os.path.join(history_dir(), x))
    if not data:
        if os.path.exists(path):
            os.remove(path)
        return
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def config_state():
    out = {"everyone": read_config(config_path("everyone")), "kids": {}}
    for k in KIDS:
        out["kids"][k["id"]] = read_config(config_path(k["id"]))
    return out


def history(scope):
    path = config_path(scope)
    name = os.path.basename(path)
    try:
        versions = sorted((x[len(name) + 1:] for x in os.listdir(history_dir()) if x.startswith(name + ".")), reverse=True)
    except FileNotFoundError:
        versions = []
    return [{"version": v, "fields": read_config(os.path.join(history_dir(), f"{name}.{v}"))} for v in versions[:30]]


# ---- HTTP -----------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "fort-parent"

    def log_message(self, fmt, *args):
        pass

    # helpers
    def cookie(self, name):
        c = SimpleCookie(self.headers.get("Cookie", ""))
        return c[name].value if name in c else None

    def authed(self):
        return session_valid(self.cookie(COOKIE))

    def send(self, code, body=b"", ctype="application/json", headers=()):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors https://ha.example.com 'self'")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def static(self, name):
        with open(os.path.join(STATIC, name), "rb") as f:
            ctype = "text/html; charset=utf-8" if name.endswith(".html") else "application/javascript" if name.endswith(".js") else "text/css"
            self.send(200, f.read(), ctype)

    def body_json(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > 100_000:
            raise ValueError("too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def session_cookie(self, token):
        return ("Set-Cookie", f"{COOKIE}={token}; Path=/; Max-Age={SESSION_DAYS*86400}; HttpOnly; Secure; SameSite=Lax")

    # routes
    def do_GET(self):
        path = urlsplit(self.path).path
        q = parse_qs(urlsplit(self.path).query)
        if path in ("/login", "/setup"):
            return self.static(path[1:] + ".html")
        if path in ("/app.js", "/auth.js", "/login.js", "/setup.js", "/settings.js", "/style.css"):
            return self.static(path[1:])
        if path == "/":
            return self.static("index.html") if self.authed() else self.send(302, b"", headers=[("Location", "/login")])
        if not path.startswith("/api/"):
            return self.send(404, {"error": "not found"})
        if not self.authed():
            return self.send(401, {"error": "sign in"})
        try:
            if path == "/api/kids":
                return self.send(200, kids_summary())
            m = re.fullmatch(r"/api/kids/([\w-]+)/(browsing|chats)", path)
            if m and kid(m.group(1)):
                k = kid(m.group(1))
                if m.group(2) == "browsing":
                    days = min(max(int((q.get("days") or ["7"])[0]), 1), 30)
                    return self.send(200, browsing(k, days))
                return self.send(200, chats(k))
            if path == "/api/config":
                return self.send(200, {**config_state(), "kidNames": {k["id"]: k["name"] for k in KIDS}})
            m = re.fullmatch(r"/api/config/([\w-]+)/history", path)
            if m and config_path(m.group(1)):
                return self.send(200, history(m.group(1)))
            m = re.fullmatch(r"/api/kids/([\w-]+)/chats/([\w-]+)", path)
            if m and kid(m.group(1)):
                d = chat_detail(kid(m.group(1)), m.group(2))
                return self.send(200, d) if d else self.send(404, {"error": "not found"})
        except Exception as e:
            print(f"error on {path}: {e!r}", flush=True)
            return self.send(502, {"error": "couldn't load that right now"})
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if self.headers.get("Origin") != ORIGIN:
            return self.send(403, {"error": "bad origin"})
        try:
            data = self.body_json()
        except Exception:
            return self.send(400, {"error": "bad request"})
        if path == "/auth/register/options":
            if not setup_code_valid(data.get("code")):
                return self.send(403, {"error": "That setup link has expired. Ask for a new one."})
            with db() as c:
                existing = [r["id"] for r in c.execute("SELECT id FROM credentials")]
            opts = webauthn.generate_registration_options(
                rp_id=RP_ID, rp_name="Fort Parent", user_name="parent", user_display_name="Parent",
                user_id=b"fort-parent", exclude_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(i)) for i in existing],
                authenticator_selection=AuthenticatorSelectionCriteria(resident_key=ResidentKeyRequirement.REQUIRED,
                                                                       user_verification=UserVerificationRequirement.REQUIRED))
            cid = save_challenge("register", opts.challenge)
            return self.send(200, {"challenge_id": cid, "options": json.loads(webauthn.options_to_json(opts))})
        if path == "/auth/register/verify":
            if not setup_code_valid(data.get("code")):
                return self.send(403, {"error": "That setup link has expired. Ask for a new one."})
            challenge = take_challenge(data.get("challenge_id", ""), "register")
            if not challenge:
                return self.send(400, {"error": "That took too long. Try again."})
            try:
                v = webauthn.verify_registration_response(credential=data["credential"], expected_challenge=challenge,
                                                          expected_rp_id=RP_ID, expected_origin=ORIGIN, require_user_verification=True)
            except Exception as e:
                print(f"registration failed: {e!r}", flush=True)
                return self.send(400, {"error": "That passkey couldn't be saved."})
            setup_code_valid(data.get("code"), consume=True)
            with db() as c:
                c.execute("INSERT INTO credentials VALUES (?,?,?,?,?,NULL)", (bytes_to_base64url(v.credential_id),
                          bytes_to_base64url(v.credential_public_key), v.sign_count, (data.get("name") or "passkey")[:60], now_iso()))
            return self.send(200, {"ok": True}, headers=[self.session_cookie(new_session())])
        if path == "/auth/login/options":
            opts = webauthn.generate_authentication_options(rp_id=RP_ID, user_verification=UserVerificationRequirement.REQUIRED)
            cid = save_challenge("login", opts.challenge)
            return self.send(200, {"challenge_id": cid, "options": json.loads(webauthn.options_to_json(opts))})
        if path == "/auth/login/verify":
            challenge = take_challenge(data.get("challenge_id", ""), "login")
            cred = data.get("credential") or {}
            with db() as c:
                row = c.execute("SELECT * FROM credentials WHERE id=?", (cred.get("id", ""),)).fetchone()
            if not challenge or not row:
                return self.send(403, {"error": "That passkey isn't set up for Fort Parent."})
            try:
                v = webauthn.verify_authentication_response(credential=cred, expected_challenge=challenge, expected_rp_id=RP_ID,
                                                            expected_origin=ORIGIN, credential_public_key=base64url_to_bytes(row["public_key"]),
                                                            credential_current_sign_count=row["sign_count"], require_user_verification=True)
            except Exception as e:
                print(f"sign-in failed: {e!r}", flush=True)
                return self.send(403, {"error": "Sign-in didn't work. Try again."})
            with db() as c:
                c.execute("UPDATE credentials SET sign_count=?, last_used=? WHERE id=?", (v.new_sign_count, now_iso(), row["id"]))
            return self.send(200, {"ok": True}, headers=[self.session_cookie(new_session())])
        m = re.fullmatch(r"/api/config/([\w-]+)(/restore)?", path)
        if m:
            if not self.authed():
                return self.send(401, {"error": "sign in"})
            target = config_path(m.group(1))
            if not target:
                return self.send(404, {"error": "not found"})
            if m.group(2):
                version = str(data.get("version", ""))
                if not re.fullmatch(r"\d{8}T\d{6}Z", version):
                    return self.send(400, {"error": "bad version"})
                fields = read_config(os.path.join(history_dir(), f"{os.path.basename(target)}.{version}"))
            else:
                fields = data.get("fields")
            problems = validate_config(fields)
            if problems:
                return self.send(400, {"error": " ".join(problems)})
            try:
                write_config(target, fields)
            except OSError as e:
                print(f"config write failed: {e!r}", flush=True)
                return self.send(500, {"error": "Couldn't save. Nothing was changed."})
            print(f"home config saved: {m.group(1)} ({', '.join(sorted(fields)) or 'cleared'})", flush=True)
            return self.send(200, {"ok": True, **config_state()})
        if path == "/auth/logout":
            end_session(self.cookie(COOKIE))
            return self.send(200, {"ok": True}, headers=[("Set-Cookie", f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax")])
        return self.send(404, {"error": "not found"})


def main():
    with db() as c:
        c.executescript(SCHEMA)
    if len(sys.argv) > 1 and sys.argv[1] == "setup-code":
        print(f"{ORIGIN}/setup#{new_setup_code()}  (valid 30 minutes, one passkey)")
        return
    with db() as c:
        if not c.execute("SELECT 1 FROM credentials").fetchone():
            print("No passkeys yet: run `python /app/app.py setup-code` for a setup link.", flush=True)
    print(f"fort-parent on :{PORT} for {ORIGIN}, kids: {[k['name'] for k in KIDS]}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
