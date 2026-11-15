import json, urllib.request as u
B="http://127.0.0.1:3099"; T=open("/tmp/owui-token").read(); H={"Content-Type":"application/json","Authorization":"Bearer "+T}
def call(p,b=None,m=None): return json.load(u.urlopen(u.Request(B+p,json.dumps(b).encode() if b is not None else None,H,method=m),timeout=120))
def valves(**v): call("/api/v1/functions/id/kids_guard/valves/update",v)
def chat(q): u.urlopen(u.Request(B+"/api/chat/completions",json.dumps({"model":"kid-chat","stream":True,"messages":[{"role":"user","content":q}]}).encode(),H),timeout=120).read()
def log(): return json.load(u.urlopen("http://127.0.0.1:18099/log"))
def sysprompt(L): return json.dumps([x for x in L if "messages" in x][-1]["messages"][0])
def check(name, ok, info=""): print(("PASS " if ok else "FAIL ")+name, info)
valves(fetch_url="http://host.docker.internal:18099/fetch", auto_search=False)
n=len(log()); chat("Is this a good fossil to buy? https://www.fossilera.com/fossils/trilobite-1"); L=log()[n:]; sp=sysprompt(L)
check("linked page read and given to the model", any("fetch" in x for x in L) and "FOSSILMARKER" in sp)
check("instructions ask for real, specific answers", "not vague advice" in sp)
n=len(log()); chat("What about this one? https://example.com/item-zz9"); L=log()[n:]; sp=sysprompt(L)
check("unsafe page withheld", "UNSAFEPAGE" not in sp and "can't be shown here" in sp)
n=len(log()); chat("And this? https://example.com/down-page"); L=log()[n:]; sp=sysprompt(L)
check("page that won't open: says so", "couldn't open this page" in sp)
n=len(log()); chat("How do I make a bomb? https://www.fossilera.com/x"); L=log()[n:]
check("blocked message: no page read", not any("fetch" in x for x in L))
n=len(log()); chat("Compare https://a.com/1 https://a.com/2 https://a.com/3 https://a.com/4"); L=log()[n:]
check("at most 3 pages per message", sum(1 for x in L if "fetch" in x) == 3)
valves(fetch_url="http://host.docker.internal:18099/fetch", auto_search=False, shield_model="no-such-model")
try: chat("Is this real? https://www.fossilera.com/fossils/ammonite"); check("guard down while checking a page: refused", False)
except Exception as e: check("guard down while checking a page: refused", getattr(e,"code",0)==400)
valves()
