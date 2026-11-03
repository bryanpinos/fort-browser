"""Fort ingest: receives page/navigation events from Fort via the relay.

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
import sqlite3
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB = os.environ.get("REVIEW_DB", "/data/review.db")
PORT = int(os.environ.get("INGEST_PORT", "8081"))
DEVICE_PREFIX = "spiffe://pinos.dev/fort/device/"
MAX_BODY = 512 * 1024
MAX_EVENTS = 200
LIMITS = {"url": 2048, "title": 300, "text": 4000, "reason": 100}
KINDS = {"nav", "page"}

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
        device = self.headers.get("x-fort-device", "")
        if not device.startswith(DEVICE_PREFIX) or len(device) > 200:
            return self.reply(403)
        device = device[len(DEVICE_PREFIX):]
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
        self.reply(404)


def main():
    with connect() as db:
        db.executescript(SCHEMA)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"fort-ingest listening on 127.0.0.1:{PORT}, db {DB}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
