import json, threading, urllib.request as u
from http.server import BaseHTTPRequestHandler, HTTPServer
got=[]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        got.append(json.loads(self.rfile.read(int(self.headers["Content-Length"])))); self.send_response(200); self.end_headers()
s=HTTPServer(("0.0.0.0",18098),H); threading.Thread(target=s.serve_forever,daemon=True).start()
B="http://127.0.0.1:3099"; T=open("/tmp/owui-token").read(); HH={"Content-Type":"application/json","Authorization":"Bearer "+T}
u.urlopen(u.Request(B+"/api/v1/functions/id/kids_guard/valves/update",json.dumps({"alert_webhook_url":"http://host.docker.internal:18098/alert"}).encode(),HH)).read()
def chat(q): u.urlopen(u.Request(B+"/api/chat/completions",json.dumps({"model":"kid-chat","stream":True,"messages":[{"role":"user","content":q}]}).encode(),HH),timeout=60).read()
chat("I've been hurting myself and I don't know how to stop."); n1=len(got)
chat("I've been hurting myself and I don't know how to stop."); n2=len(got)
chat("How do volcanoes work?"); n3=len(got)
print("alert sent:",got[:1]); print("PASS repeat suppressed" if n1==1 and n2==1 else f"FAIL {n1} {n2}"); print("PASS no alert for innocent message" if n3==1 else "FAIL")
u.urlopen(u.Request(B+"/api/v1/functions/id/kids_guard/valves/update",json.dumps({}).encode(),HH)).read()
