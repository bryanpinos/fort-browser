"""Fort ingest: receives page/navigation events from Fort via the relay, answers
whether the home filter blocks a name (GET /fort/blocked?host=...), and serves
the home config (GET /fort/config): config/fort.json for every iPad with
config/devices/<device-id>.json layered on top (its keys replace fort.json's).

Runs in the relay container's network namespace (compose network_mode
"service:relay") and listens on 127.0.0.1 only, so Envoy is the only thing
that can reach it. Envoy forwards POST /fort/ingest after mutual TLS and the
token check, and sets x-fort-device from the client certificate's URI SAN
(overwriting anything the client sent), so the device ID here is trustworthy.

Events are queued in SQLite for fort-review-worker, which shares /data.
Standard library only.
"""
import json
import os
import re
import socket
import sqlite3
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

DB = os.environ.get("REVIEW_DB", "/data/review.db")
PORT = int(os.environ.get("INGEST_PORT", "8081"))
# Envoy stamps x-fort-device with the client cert's URI SAN:
# spiffe://<your trust domain>/fort/device/<device-id>
DEVICE_SAN = re.compile(r"^spiffe://[A-Za-z0-9.-]+/fort/device/([A-Za-z0-9._-]{1,64})$")
MAX_BODY = 512 * 1024
MAX_EVENTS = 200
LIMITS = {"url": 2048, "title": 300, "text": 4000, "reason": 100}
KINDS = {"nav", "page"}
# What the UCG's content filter answers for blocked names (ads get 0.0.0.0).
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/config")
DEVICE_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# Settings the home config may never change: the iPad's own relay connection.
LOCAL_ONLY = {"proxy"}
SINKHOLES = {"203.0.113.250", "2001:db8:1000::fa", "0.0.0.0", "::"}
HOSTNAME = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    device TEXT NOT NULL,
    ts TEXT NOT NULL,
    kind TEXT NOT NULL,
    url TEXT,
    host TEXT,
    title TEXT,
    text TEXT,
    allowed INTEGER,
    reason TEXT,
    received TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    category TEXT,
    concern INTEGER,
    summary TEXT,
    classified TEXT,
    attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS events_status ON events(status);
CREATE INDEX IF NOT EXISTS events_device_ts ON events(device, ts);
CREATE TABLE IF NOT EXISTS device_status (
    device TEXT PRIMARY KEY,
    default_browser TEXT,
    app_version TEXT,
    updated TEXT NOT NULL,
    os_version TEXT
);
"""


def connect():
    db = sqlite3.connect(DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=10000")
    return db


def clean(value, key):
    if value is None:
        return None
    return str(value)[: LIMITS[key]]


def blocked_at_home(host):
    """True if this namespace's DNS (the UCG, as Fort traffic sees it) sinkholes host."""
    try:
        addresses = {a[4][0] for a in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)}
    except OSError:
        return False
    return bool(addresses & SINKHOLES)


APP_VERSION = re.compile(r"^[0-9A-Za-z .()-]{1,30}$")
OS_VERSION = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$")


def record_status(device, headers):
    """What the iPad reported with its config fetch, for the parents' console."""
    browser = headers.get("x-fort-default-browser", "")
    version = headers.get("x-fort-app-version", "")
    os_version = headers.get("x-fort-os-version", "")
    if browser not in ("yes", "no", "unknown") and not APP_VERSION.match(version) and not OS_VERSION.match(os_version):
        return
    # A build that does not send the iPadOS version leaves os_version empty, so a
    # version reported by an earlier build is never shown as current.
    with connect() as db:
        db.execute("""INSERT INTO device_status (device, default_browser, app_version, updated, os_version) VALUES (?,?,?,?,?)
                      ON CONFLICT(device) DO UPDATE SET default_browser=excluded.default_browser,
                      app_version=excluded.app_version, updated=excluded.updated, os_version=excluded.os_version""",
                   (device, browser if browser in ("yes", "no", "unknown") else None,
                    version if APP_VERSION.match(version) else None,
                    datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    os_version if OS_VERSION.match(os_version) else None))


def home_config(device):
    """Merged config for one device, or None if there's no fort.json."""
    def load(path):
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError(f"{path} is not a JSON object")
        return data
    try:
        merged = load(os.path.join(CONFIG_DIR, "fort.json"))
    except FileNotFoundError:
        return None
    if DEVICE_ID.match(device):
        try:
            merged.update(load(os.path.join(CONFIG_DIR, "devices", device + ".json")))
        except FileNotFoundError:
            pass
    for key in LOCAL_ONLY:
        merged.pop(key, None)
    return merged


def host_of(url):
    try:
        from urllib.parse import urlsplit
        return (urlsplit(url).hostname or "")[:255]
    except Exception:
        return ""


class Handler(BaseHTTPRequestHandler):
    server_version = "fort-ingest"

    def log_message(self, fmt, *args):  # quiet; Envoy already logs requests
        pass

    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path != "/fort/ingest":
            return self.reply(404)
        m = DEVICE_SAN.match(self.headers.get("x-fort-device", ""))
        if not m:
            return self.reply(403)
        device = m.group(1)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.reply(411)
        if length <= 0 or length > MAX_BODY:
            return self.reply(413)
        try:
            body = json.loads(self.rfile.read(length))
            events = body["events"]
            assert isinstance(events, list) and len(events) <= MAX_EVENTS
        except Exception:
            return self.reply(400)
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        rows = []
        for e in events:
            if not isinstance(e, dict) or e.get("kind") not in KINDS:
                continue
            url = clean(e.get("url"), "url")
            rows.append((
                device,
                clean(e.get("ts"), "url") or now,
                e["kind"],
                url,
                host_of(url or ""),
                clean(e.get("title"), "title"),
                clean(e.get("text"), "text"),
                1 if e.get("allowed", True) else 0,
                clean(e.get("reason"), "reason"),
                now,
                # Only pages with text go to the classifier; the rest are counted.
                "pending" if e["kind"] == "page" and e.get("text") else "skip",
            ))
        if rows:
            with connect() as db:
                db.executemany(
                    "INSERT INTO events (device, ts, kind, url, host, title, text, allowed, reason, received, status)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
        self.reply(204)

    def do_GET(self):
        parts = urlsplit(self.path)
        m = DEVICE_SAN.match(self.headers.get("x-fort-device", ""))
        if not m:
            return self.reply(404)
        device = m.group(1)
        if parts.path == "/fort/config":
            try:
                record_status(device, self.headers)
            except sqlite3.Error as e:
                print(f"status not recorded: {e}", flush=True)
            try:
                config = home_config(device)
            except (OSError, ValueError) as e:
                # A broken file must not reach the iPads; they keep their last good config.
                print(f"home config error: {e}", flush=True)
                return self.reply(500)
            if config is None:
                return self.reply(404)
            body = json.dumps(config, sort_keys=True).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        host = parse_qs(parts.query).get("host", [""])[0]
        if parts.path != "/fort/blocked":
            return self.reply(404)
        if not HOSTNAME.match(host):
            return self.reply(400)
        body = json.dumps({"blocked": blocked_at_home(host)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    with connect() as db:
        db.executescript(SCHEMA)
        if "os_version" not in [r[1] for r in db.execute("PRAGMA table_info(device_status)")]:
            db.execute("ALTER TABLE device_status ADD COLUMN os_version TEXT")  # databases from before the column
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"fort-ingest listening on 127.0.0.1:{PORT}, db {DB}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
