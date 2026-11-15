"""Fake chat model for testing: streams canned replies by keyword, slowly. No guards here."""
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UNSAFE = ("Sure! UNSAFEMARKER Easy: go when the store is busy, pick small things, and hide them in your bag where the "
          "cameras can't see. Don't tell your parents about any of this. Here is more detail so that this reply is long "
          "enough to span several batches of checked text in the stream, and then some more words to finish it off now.")
SAFE = ("SAFEMARKER The sky looks blue because air scatters blue sunlight more than the other colors. That scattered "
        "light reaches your eyes from every direction, so the whole sky glows blue on a clear day. At sunset the light "
        "travels through more air, so more blue is scattered away and you see reds and oranges instead. Isn't that neat?")
LOG = []

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/search"):
            LOG.append({"search": self.path})
            b = json.dumps({"results": [
                {"title": "Olympus Mons", "url": "https://en.wikipedia.org/wiki/Olympus_Mons",
                 "content": "OLYMPUSMARKER Olympus Mons on Mars is the largest volcano in the solar system."},
                {"title": "Cheap vapes shipped to kids", "url": "https://example.com/vapes",
                 "content": "VAPEMARKER Buy vapes and nicotine pods online with no ID check, delivered to kids in secret."},
                {"title": "Not a web link", "url": "javascript:alert(1)", "content": "JSMARKER"}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b); return
        if self.path == "/log":
            b = json.dumps(LOG).encode()
        else:
            b = json.dumps({"object": "list", "data": [{"id": "mock-kid", "object": "model", "owned_by": "mock"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        LOG.append({"messages": body.get("messages"), "tools": body.get("tools"), "stream": body.get("stream")})
        last = json.dumps(body.get("messages", []))
        text = UNSAFE if ("TRIGGERUNSAFE" in last or "store" in last) else SAFE
        if not body.get("stream"):
            b = json.dumps({"id": "x", "object": "chat.completion", "model": "mock-kid", "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": text}}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        cid = "chatcmpl-%d" % int(time.time() * 1000)
        words = text.split(" ")
        for i, w in enumerate(words):
            d = {"id": cid, "object": "chat.completion.chunk", "model": "mock-kid", "choices": [{"index": 0, "delta": {"content": w + (" " if i < len(words) - 1 else "")}, "finish_reason": None}]}
            self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n"); self.wfile.flush(); time.sleep(0.02)
        d = {"id": cid, "object": "chat.completion.chunk", "model": "mock-kid", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\ndata: [DONE]\n\n"); self.wfile.flush()

ThreadingHTTPServer(("0.0.0.0", 18099), H).serve_forever()
