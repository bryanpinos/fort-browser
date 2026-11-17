# The relay

The relay is a small server at home that Fort sends every page through. Your home network's content filter then applies wherever the iPad is (school Wi-Fi, a friend's house, a phone hotspot), and if home can't be reached, Fort simply doesn't browse.

It's [Envoy](https://www.envoyproxy.io/) acting as an [Apple network relay](https://developer.apple.com/documentation/network/relay) (HTTP/2 CONNECT over TLS), with three locks on the door:
1. **Mutual TLS.** Each iPad has its own certificate from **your family's private certificate authority**. Without one that's on your allowlist, the connection is refused during the TLS handshake.
2. **A token,** checked on every request.
3. **No way into your home network:** private addresses, bare IP addresses, your own domains and ports other than 80/443 are refused. Underneath, you isolate it on its own VLAN.

Everything below lives in `server/relay/`.

## What you need
- A machine at home that runs Docker (a NAS, a mini PC, a Raspberry Pi 4/5) and stays on.
- A domain name for the relay, e.g. `relay.example.com`, with a public DNS record pointing at your home's public IP, and a TLS certificate for it. The `route53` profile does both automatically if your domain is on AWS Route 53; otherwise use any DNS provider and any way of getting a Let's Encrypt certificate.
- A router that can forward one port (8443) to the relay.
- Recommended: a router that supports VLANs and per-network content filtering (UniFi, pfSense/OPNsense, Firewalla…), or a filtering DNS (NextDNS, Pi-hole, AdGuard Home) the relay uses.
- [`step`](https://smallstep.com/docs/step-cli/installation) on your computer, to make certificates.

## 1. Settings
```sh
cd server/relay
cp .env.example .env && chmod 600 .env     # then edit it
openssl rand -hex 24 > token && chmod 600 token
chmod 700 .                                 # the folder will hold the token and keys
```
Set at least `RELAY_DOMAIN` and `INTERNAL_DOMAINS`. `COMPOSE_PROFILES` turns on optional parts (`route53`, `review`, `monitoring`, `chat`, `unifi`); start with none.

## 2. The relay's certificate
The relay needs `certs/relay.crt` (full chain) and `certs/relay.key` for `RELAY_DOMAIN`, readable by Envoy (user 65532):
```sh
mkdir -p certs && chmod 755 certs
# copy your cert and key in, then:
sudo chown 65532:65532 certs/relay.crt certs/relay.key && sudo chmod 644 certs/relay.crt && sudo chmod 400 certs/relay.key
```
With the **`route53`** profile, `relay-cert` gets and renews a Let's Encrypt certificate itself (DNS-01) and `ddns` keeps the A record on your public IP; set the `AWS_*` and `LEGO_EMAIL` lines. Use an IAM user limited to your zone. Envoy reloads renewed certificates without a restart.

## 3. Your family's certificate authority
On your computer, in `server/relay/pki/`:
```sh
./new-ca.sh "Smith Fort Client CA"          # asks for a passphrase for the CA key
mkdir -p ../ca && cp fort-ca.crt ../ca/      # public: goes to the relay
```
Keep `fort-ca.key` and its passphrase somewhere safe and offline (a password manager is fine); you need them only when adding an iPad. Delete the copy on disk.

## 4. A certificate for each iPad
Choose a short ID per iPad (`ava-ipad`) and a *trust domain* (your domain, e.g. `example.com`):
```sh
./new-device.sh example.com ava-ipad "Ava's iPad"   # asks for the CA passphrase and a password for the .p12
```
It prints the line to add to the allowlist. Create the allowlist once from the example:
```sh
mkdir -p ../clients && cp ../clients.example.yaml ../clients/clients.yaml   # then edit: one matcher per iPad
```
Each iPad's identity is `spiffe://<trust domain>/fort/device/<id>`. The relay records activity under that ID, so use something you'll recognize.

## 5. Start it
```sh
cd server/relay
python3 render.py               # writes envoy.yaml from the template, .env and token
docker run --rm --user 65532 -v $PWD/envoy.yaml:/etc/envoy/envoy.yaml:ro -v $PWD/certs:/certs:ro \
  -v $PWD/ca:/ca:ro -v $PWD/clients:/etc/envoy/clients:ro \
  envoyproxy/envoy:distroless-v1.40-latest --mode validate -c /etc/envoy/envoy.yaml   # look for "OK"
docker compose up -d
```
After changing `envoy.template.yaml` or `.env`, run `render.py` again and `docker compose up -d --force-recreate relay ingest`.

## 6. The port forward
Forward **TCP 8443** from the internet to the relay: to the Docker host (plain network) or to `RELAY_IP` (VLAN overlay). Nothing else needs to be opened. Expect internet scanners to knock within hours; they're refused at the TLS handshake and never reach the relay itself.

## 7. Isolate it on its own VLAN
The relay talks to the internet on your kids' behalf, so it shouldn't be able to reach anything else at home. The best setup is its own VLAN:

1. **Create a VLAN** for it (e.g. VLAN 40, `192.168.40.0/24`, no DHCP needed) and carry it, tagged, to the Docker host's switch port. On Linux the host gets an interface like `eth0.40`.
2. **Use the overlay:** in `.env`, `COMPOSE_FILE=docker-compose.yaml:docker-compose.vlan.yaml` and the `VLAN_*`, `RELAY_*`, `KIDS_*` addresses. The relay then has its own address and MAC on that VLAN.
3. **Firewall rules** on your router, for traffic *from* that VLAN:
   - allow DNS to the gateway;
   - allow only what you use at home: MQTT to Home Assistant (`monitoring`), the reverse proxy in front of Fort Chat on 443 (`KIDS_CHAT_*`);
   - **block new connections to every private network** (`10/8`, `172.16/12`, `192.168/16`) **and to the gateway itself**.
4. **Apply your kids' content filter** to that VLAN: category blocking, SafeSearch, ad blocking. Everything the relay fetches gets it.

On the plain Docker network instead, at least point the relay's DNS at a filtering resolver and block it from your LAN with host firewall rules.

### Worked example: UniFi
With a UniFi gateway (UCG/UDM), network `Fort` = VLAN 40, no DHCP:
- *Firewall (classic rules)*, source network Fort: **LAN In** accept `192.168.40.0/24` → MQTT host TCP 1883; accept → reverse proxy TCP 443; then drop new → an RFC1918 address group. **LAN Local** accept → gateway TCP/UDP 53; then drop other new → gateway. Read the rules back after saving: the API and UI can silently reorder them.
- *Content filtering*: a policy scoped to the Fort network with the categories you want, SafeSearch and Ad Block.
- UniFi answers blocked names with a sinkhole address that **never answers from an isolated VLAN**, so a blocked site would wait out a 5-second timeout before Fort could show its block page. Add `unifi` to `COMPOSE_PROFILES`: a tiny helper routes the sinkhole as unreachable so blocks are instant. Fort then asks the relay "is this blocked?" and shows its block page.

## 8. Set up each iPad
In Fort's **Parent settings**:
1. **Proxy:** turn on *Pin all traffic through a proxy*, Type **Relay**, Host = `RELAY_DOMAIN`, Port `8443`, *Relay token* = the contents of `token`.
2. **Relay certificate › Import certificate…:** the iPad's `.p12`. AirDropping a bare `.p12` makes iOS offer to install a profile; zip it first, unzip in Files, then import. Delete the copies afterward. The certificate is kept in the iPad's keychain, never backed up.
3. Leave **Probe URL** empty: with a relay, Fort checks home through the relay itself.
4. **Save**, and allow **Local Network** when iOS asks.

## Check it works
- Open a site on the iPad, then try one your home filter blocks: you should see Fort's block page.
- `docker logs fort-relay` shows one line per tunnel with the iPad's ID (`peer=…`). Lines starting `CONN` show refused handshakes and why.
- From your computer: `curl --http2 --cert-type P12 --cert ava-ipad.p12:PASSWORD -H "x-fort-token: $(cat token)" https://relay.example.com:8443/fort/health` prints `ok`. Without the certificate, the connection is refused.

## Day to day
- **Add an iPad:** `new-device.sh`, add its line to `clients/clients.yaml`.
- **Remove an iPad:** delete its line. Edit a copy and move it into place (`cp clients/clients.yaml /tmp/c.yaml`, edit, `mv /tmp/c.yaml clients/clients.yaml`) so Envoy sees one atomic change; it reloads within seconds, no restart.
- **Rotate the token:** `openssl rand -hex 24 > token`, `python3 render.py`, restart the relay, update each iPad.
- **Updates:** `docker compose pull && docker compose up -d`. The image tag stays within Envoy 1.40.x; check [Envoy's advisories](https://github.com/envoyproxy/envoy/security/advisories) before moving to a new minor version.

## Optional profiles
| Profile | Adds | Guide |
|---|---|---|
| `route53` | Let's Encrypt certificate + dynamic DNS via Route 53 | above |
| `review` | Page review with a local AI | [Page review](page-review.md) |
| `monitoring` | Relay health and certificate expiry in Home Assistant (MQTT discovery) | below |
| `chat` | Kids' search and page reader for Fort Chat | [Fort Chat](fort-chat.md) |
| `unifi` | Instant block pages behind a UniFi content filter | above |

**Monitoring** publishes `binary_sensor.fort_relay_relay_up`, certificate days left, tunnels and refusals per hour. Useful alerts: relay down for 5 minutes, certificate under 20 days, and *any rejected client certificate* (a revoked, expired or leaked certificate; scanners never present one).

## Troubleshooting
- **Pages are blank after setup:** the Local Network prompt hasn't been answered, or the iPad has no certificate. Parent settings shows the certificate and its expiry.
- **"Fort works from home":** the relay isn't reachable. Check the port forward and DNS from outside your network (a phone on cellular).
- **The relay keeps restarting:** `docker logs fort-relay`. "unable to read file" means Envoy can't read `envoy.yaml` or the certificates (permissions, see steps 2 and 5).
- **Every connection from home shows the router's address:** that's NAT loopback (hairpin). Tell iPads apart by `peer=`.
