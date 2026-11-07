import json, urllib.request as u, sys
B="http://127.0.0.1:3099"
def call(path, body=None, token=None, method=None):
    h={"Content-Type":"application/json"}
    if token: h["Authorization"]="Bearer "+token
    r=u.Request(B+path, json.dumps(body).encode() if body is not None else None, h, method=method)
    with u.urlopen(r,timeout=60) as x: return json.load(x)
a=call("/api/v1/auths/signup",{"name":"Test Admin","email":"admin@test.invalid","password":"throwaway-Pw1!"})
T=a["token"]; open("/tmp/owui-token","w").write(T)
src=open("../kids_guard_filter.py").read()
call("/api/v1/functions/create",{"id":"kids_guard","name":"Kids Guard","content":src,"meta":{"description":"test"}},T)
print("active:",call("/api/v1/functions/id/kids_guard/toggle",{},T,"POST").get("is_active"))
print(call("/api/v1/functions/id/kids_guard/valves/update",{"qwen_model":"guard-qwen","shield_model":"guard-shield"},T))
m=call("/api/v1/models/create",{"id":"kid-chat","base_model_id":"mock-kid","name":"Kid Chat","meta":{"description":"t","filterIds":["kids_guard"]},"params":{}},T)
print("model:",m.get("id"),m.get("meta",{}).get("filterIds"))
