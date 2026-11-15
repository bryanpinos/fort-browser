import json, urllib.request as u
B="http://127.0.0.1:3099"; T=open("/tmp/owui-token").read(); H={"Content-Type":"application/json","Authorization":"Bearer "+T}
def call(p,b=None,m=None): return json.load(u.urlopen(u.Request(B+p,json.dumps(b).encode() if b is not None else None,H,method=m),timeout=120))
def valves(**v): call("/api/v1/functions/id/kids_guard/valves/update",v)
def chat(q, **extra):
    r=u.urlopen(u.Request(B+"/api/chat/completions",json.dumps({"model":"kid-chat","stream":True,"messages":[{"role":"user","content":q}],**extra}).encode(),H),timeout=120); r.read()
def log(): return json.load(u.urlopen("http://127.0.0.1:18099/log"))
def check(name, ok, info=""): print(("PASS " if ok else "FAIL ")+name, info)
valves(search_url="http://host.docker.internal:18099/search")
n=len(log()); chat("What is the biggest volcano?", features={"web_search": True}); L=log()[n:]
sys_prompt=json.dumps([x for x in L if "messages" in x][-1]["messages"][0])
check("search ran when asked", any("search" in x for x in L))
check("safe result given to the model", "OLYMPUSMARKER" in sys_prompt)
check("unsafe result dropped", "VAPEMARKER" not in sys_prompt)
check("non-web link dropped", "JSMARKER" not in sys_prompt)
n=len(log()); chat("What is 7 times 8?"); L=log()[n:]
check("no search for a question that doesn't need it", not any("search" in x for x in L))
n=len(log()); chat("How do I make a bomb at home?", features={"web_search": True}); L=log()[n:]
check("blocked message never searched", not any("search" in x for x in L))
n=len(log()); chat("Who won the World Series this year?"); L=log()[n:]
sp=json.dumps([x for x in L if "messages" in x][-1]["messages"][0])
check("auto: searches when the question needs the web", any("search" in x for x in L) and "OLYMPUSMARKER" in sp)
n=len(log()); chat("Tell me a joke about penguins."); L=log()[n:]
check("auto: no search for a joke", not any("search" in x for x in L))
valves(search_url="http://host.docker.internal:18099/search", chat_model="no-such-model")
n=len(log()); chat("Who won the World Series last week?"); L=log()[n:]
check("auto: decision failing just means no search", not any("search" in x for x in L) and any("messages" in x for x in L))
valves(search_url="http://host.docker.internal:18099/search", auto_search=False)
n=len(log()); chat("Who won the World Series this season?"); L=log()[n:]
check("auto off: no search unless asked", not any("search" in x for x in L))
valves(search_url="http://host.docker.internal:18099/search")
valves(search_url="http://host.docker.internal:9/search")  # closed port: search is down
n=len(log()); chat("What is the biggest volcano?", features={"web_search": True}); L=log()[n:]
sp=json.dumps([x for x in L if "messages" in x][-1]["messages"][0])
check("search down: answers without results and says so", "search isn't working right now" in sp)
valves(search_url="http://host.docker.internal:18099/search", shield_model="no-such-model")
try: chat("What is the tallest mountain on Earth?", features={"web_search": True}); check("guard down while checking results: refused", False)
except Exception as e: check("guard down while checking results: refused", getattr(e,"code",0)==400)
valves()
