"""Kids' page reader for Fort Chat: fetches a public web page and returns its text.

Runs on the Fort VLAN (like fort-kids-search), so the UCG's Kids content filter
applies: a blocked site's name resolves to the sinkhole and the fetch fails.
Only the Kids Guard filter calls it, and it checks the text before the model
sees any of it. Standard library only.
"""
import ipaddress, json, os, re, socket, sys
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
import urllib.request

PORT = int(os.environ.get("PORT", "8080"))
ALLOWED_CLIENTS = set(filter(None, os.environ.get("ALLOWED_CLIENTS", "").split(",")))
CONTACT_EMAIL = os.environ.get("CONTACT_EMAIL", "")
MAX_BYTES = 2_000_000
MAX_TEXT = 6000
TIMEOUT = 10


class Text(HTMLParser):
    SKIP = {"script", "style", "noscript", "svg", "template", "nav", "footer", "header", "form"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self.description, self.parts, self._skip, self._in_title = "", "", [], 0, False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in self.SKIP:
            self._skip += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "meta" and (a.get("name") or a.get("property") or "").lower() in ("description", "og:description"):
            self.description = self.description or (a.get("content") or "")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip:
            self._skip -= 1
        elif tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        elif not self._skip and data.strip():
            self.parts.append(data.strip())


def public_host(host):
    """Names only (no bare IPs), resolving only to public addresses."""
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    try:
        addrs = {i[4][0] for i in socket.getaddrinfo(host, 443)}
    except OSError:
        return False
    return bool(addrs) and all(ipaddress.ip_address(a).is_global for a in addrs)


class NoPrivateRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        u = urlsplit(newurl)
        if u.scheme not in ("http", "https") or not u.hostname or not public_host(u.hostname):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url):
    u = urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname or (u.port or 443 if u.scheme == "https" else u.port or 80) not in (80, 443):
        return 400, {"error": "only http(s) pages on ports 80/443"}
    if not public_host(u.hostname):
        return 403, {"error": "blocked or not a public site"}
    opener = urllib.request.build_opener(NoPrivateRedirects)
    agent = "FortKidsReader/1.0" + (f" (+mailto:{CONTACT_EMAIL})" if CONTACT_EMAIL else "")
    req = urllib.request.Request(url, headers={"User-Agent": agent,
                                               "Accept": "text/html,text/plain"})
    try:
        with opener.open(req, timeout=TIMEOUT) as r:
            ctype = r.headers.get("Content-Type", "")
            if not ctype.startswith(("text/html", "text/plain")):
                return 415, {"error": "not a web page"}
            raw = r.read(MAX_BYTES)
            charset = r.headers.get_content_charset() or "utf-8"
    except Exception as e:
        return 502, {"error": f"couldn't open the page: {type(e).__name__}"}
    html = raw.decode(charset, "replace")
    if ctype.startswith("text/plain"):
        return 200, {"url": url, "title": "", "description": "", "text": html[:MAX_TEXT]}
    p = Text()
    p.feed(html)
    text = re.sub(r"\s+", " ", " ".join(p.parts))
    return 200, {"url": url, "title": p.title.strip()[:300], "description": p.description.strip()[:500], "text": text[:MAX_TEXT]}


class Handler(BaseHTTPRequestHandler):
    server_version = "fort-kids-fetch"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if ALLOWED_CLIENTS and self.client_address[0] not in ALLOWED_CLIENTS:
            return self.reply(403, {"error": "not allowed"})
        parts = urlsplit(self.path)
        if parts.path != "/fetch":
            return self.reply(404, {"error": "not found"})
        url = parse_qs(parts.query).get("url", [""])[0]
        self.reply(*fetch(url))

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    if not ALLOWED_CLIENTS:
        sys.exit("set ALLOWED_CLIENTS (the Open WebUI host's address): refusing to run open to everyone")
    print(f"fort-kids-fetch on :{PORT}, clients {sorted(ALLOWED_CLIENTS) or 'any'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
