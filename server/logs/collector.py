"""Tiny activity-log collector for Fort.

POST /log  {"device": "...", "entries": [{"timestamp": ..., "url": ..., "allowed": ..., "reason": ...}]}
GET  /     last 200 lines as text (quick look from a browser on the tailnet)

Appends JSON lines to /data/fort.jsonl. Swap for Loki/Elastic/HA later.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

LOG = Path("/data/fort.jsonl")
LOG.parent.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/log":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
            device = body.get("device", "unknown")
            with LOG.open("a") as f:
                for e in body.get("entries", []):
                    e["device"] = device
                    f.write(json.dumps(e) + "\n")
        except (ValueError, KeyError, AttributeError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        lines = LOG.read_text().splitlines()[-200:] if LOG.exists() else []
        out = "\n".join(reversed(lines)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8089), Handler).serve_forever()
