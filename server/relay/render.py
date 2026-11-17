#!/usr/bin/env python3
"""Renders envoy.yaml from envoy.template.yaml, .env and the token file.

    python3 render.py            # writes envoy.yaml (mode 644; keep the directory 700)
    python3 render.py --check    # renders to stdout-free temp and validates only

Fills {{RELAY_TOKEN}} (from ./token), {{INTERNAL_DOMAINS_REGEX}} (from
INTERNAL_DOMAINS, e.g. "example.com home.example.net"), and the optional Fort
Chat route ({{KIDS_CHAT_HOST}}, {{KIDS_CHAT_UPSTREAM_IP}}, {{KIDS_CHAT_UPSTREAM_PORT}});
without KIDS_CHAT_HOST the route and its cluster are left out. Refuses to
write anything with a {{placeholder}} left.
"""
import ipaddress, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def env_file(path):
    values = {}
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return {**values, **{k: v for k, v in os.environ.items() if k in values or k.startswith(("KIDS_CHAT", "INTERNAL_DOMAINS"))}}


def main():
    env = env_file(os.path.join(HERE, ".env"))
    token = open(os.path.join(HERE, "token")).read().strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{24,}", token):
        sys.exit("token must be at least 24 letters/digits (openssl rand -hex 24 > token)")
    domains = env.get("INTERNAL_DOMAINS", "").split()
    for d in domains:
        if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+", d):
            sys.exit(f"INTERNAL_DOMAINS: {d!r} isn't a domain name")
    s = open(os.path.join(HERE, "envoy.template.yaml")).read()
    host = env.get("KIDS_CHAT_HOST", "")
    if host:
        ip, port = env.get("KIDS_CHAT_UPSTREAM_IP", ""), env.get("KIDS_CHAT_UPSTREAM_PORT", "443")
        ipaddress.ip_address(ip)  # must be a literal address
        if not port.isdigit():
            sys.exit("KIDS_CHAT_UPSTREAM_PORT must be a number")
        s = s.replace("{{KIDS_CHAT_HOST}}", host).replace("{{KIDS_CHAT_UPSTREAM_IP}}", ip).replace("{{KIDS_CHAT_UPSTREAM_PORT}}", port)
        s = re.sub(r"[ \t]*# \{\{[#/]KIDS_CHAT\}\}\n", "", s)
    else:
        s = re.sub(r"[ \t]*# \{\{#KIDS_CHAT\}\}\n.*?# \{\{/KIDS_CHAT\}\}\n", "", s, flags=re.S)
    s = s.replace("{{INTERNAL_DOMAINS_REGEX}}", "".join(re.escape(d).replace("\\", "\\\\") + "|" for d in domains))
    s = s.replace("{{RELAY_TOKEN}}", token)
    left = re.findall(r"\{\{[^}]*\}\}", s)
    if left:
        sys.exit(f"unfilled placeholders: {sorted(set(left))}")
    if "--check" in sys.argv:
        print("ok")
        return
    out = os.path.join(HERE, "envoy.yaml")
    tmp = out + ".new"
    # 0644, not 0600: Envoy runs as uid 65532 and must read it. Keep the stack
    # directory itself 0700 (owner only) so the token isn't readable by others.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    with os.fdopen(fd, "w") as f:
        f.write(s)
    os.chmod(tmp, 0o644)  # os.open's mode is filtered by the umask
    os.replace(tmp, out)
    print(f"wrote {out}. Restart the relay to load it: docker compose up -d --force-recreate relay ingest monitor sinkhole-route")


if __name__ == "__main__":
    main()
