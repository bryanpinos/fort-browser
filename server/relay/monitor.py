"""Fort relay monitor: Envoy stats + cert expiry -> Home Assistant via MQTT.

Runs in the relay container's network namespace (compose network_mode
"service:relay"), so it reads Envoy's admin API on 127.0.0.1:9901, which is
reachable from nowhere else. The NAS's fort_relay nft table lets this
namespace reach only MQTT (and DNS) on the LAN. Standard library only.
"""
import json
import os
import socket
import ssl
import struct
import time
import urllib.request
from collections import deque
from datetime import datetime, timezone

MQTT_HOST = os.environ.get("MQTT_HOST", "192.168.1.10")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
ADMIN = "http://127.0.0.1:9901"
CERT = "/certs/relay.crt"
PREFIX = "fort_relay"
STATUS = f"{PREFIX}/status"
STATE = f"{PREFIX}/state"
INTERVAL = 60
WINDOW = 60  # minutes kept for "last hour" counts

DEVICE = {"identifiers": ["fort_relay"], "name": "Fort relay", "manufacturer": "Envoy", "model": "Fort relay (NAS)"}

SENSORS = {
    # key: (component, name, extra discovery fields)
    "up": ("binary_sensor", "Relay up", {"device_class": "connectivity", "payload_on": "ON", "payload_off": "OFF"}),
    "cert_days_left": ("sensor", "Certificate days left", {"unit_of_measurement": "d", "icon": "mdi:certificate"}),
    "tunnels_1h": ("sensor", "Tunnels last hour", {"unit_of_measurement": "tunnels", "state_class": "measurement", "icon": "mdi:tunnel"}),
    "token_refused_1h": ("sensor", "Requests refused last hour", {"unit_of_measurement": "requests", "state_class": "measurement", "icon": "mdi:shield-alert"}),
    "tls_refused_1h": ("sensor", "TLS handshakes refused last hour", {"unit_of_measurement": "handshakes", "state_class": "measurement", "icon": "mdi:shield-lock"}),
    "bad_cert_1h": ("sensor", "Rejected client certificates last hour", {"unit_of_measurement": "handshakes", "state_class": "measurement", "icon": "mdi:certificate-outline"}),
    "active_connections": ("sensor", "Active connections", {"unit_of_measurement": "connections", "state_class": "measurement", "icon": "mdi:lan-connect"}),
}

# Envoy counters summed into each "last hour" figure.
COUNTERS = {
    # Upstream connections opened by the forward proxy = real tunnels. (The
    # 2xx request count would also include every /fort/health check.)
    "tunnels_1h": ["cluster.dfp.upstream_cx_total"],
    "token_refused_1h": ["http.relay.downstream_rq_4xx"],
    # A client certificate was presented but rejected (wrong CA, expired, or not
    # on the allowlist): actionable, unlike scanners that present none.
    "bad_cert_1h": ["listener.0.0.0.0_8443.ssl.fail_verify_error",
                    "listener.0.0.0.0_8443.ssl.fail_verify_san",
                    "listener.0.0.0.0_8443.ssl.fail_verify_cert_hash"],
    "tls_refused_1h": ["listener.0.0.0.0_8443.ssl.fail_verify_no_cert",
                       "listener.0.0.0.0_8443.ssl.fail_verify_error",
                       "listener.0.0.0.0_8443.ssl.fail_verify_san",
                       "listener.0.0.0.0_8443.ssl.connection_error"],
}


# --- minimal MQTT 3.1.1 (QoS 0) -------------------------------------------

def _varint(n):
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _str(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b


class MQTT:
    def __init__(self):
        self.sock = None

    def connect(self):
        s = socket.create_connection((MQTT_HOST, MQTT_PORT), timeout=10)
        # clean session + retained last will "offline" on STATUS
        flags = 0x02 | 0x04 | 0x20
        var = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", INTERVAL * 3)
        payload = _str("fort-relay-monitor") + _str(STATUS) + _str("offline")
        body = var + payload
        s.sendall(bytes([0x10]) + _varint(len(body)) + body)
        ack = s.recv(4)
        if len(ack) < 4 or ack[0] != 0x20 or ack[3] != 0:
            raise ConnectionError(f"MQTT CONNACK refused: {ack!r}")
        self.sock = s

    def publish(self, topic, payload, retain=False):
        body = _str(topic) + payload.encode()
        self.sock.sendall(bytes([0x30 | (1 if retain else 0)]) + _varint(len(body)) + body)

    def ping(self):
        self.sock.sendall(b"\xc0\x00")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass
        self.sock = None


# --- data -------------------------------------------------------------------

def envoy_stats():
    with urllib.request.urlopen(f"{ADMIN}/stats?format=json", timeout=5) as r:
        data = json.load(r)
    return {s["name"]: s.get("value", 0) for s in data.get("stats", []) if "name" in s}


def envoy_ready():
    try:
        with urllib.request.urlopen(f"{ADMIN}/ready", timeout=5) as r:
            return r.read().strip() == b"LIVE"
    except Exception:
        return False


def cert_days_left():
    try:
        not_after = ssl._ssl._test_decode_cert(CERT)["notAfter"]  # e.g. 'Jan 30 21:36:36 2027 GMT'
        expiry = datetime.strptime(not_after, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        return round((expiry - datetime.now(timezone.utc)).total_seconds() / 86400, 1)
    except Exception:
        return None


def discovery(mqtt):
    for key, (component, name, extra) in SENSORS.items():
        cfg = {
            "name": name,
            "unique_id": f"fort_relay_{key}",
            "object_id": f"fort_relay_{key}",
            "state_topic": STATE,
            "value_template": "{{ value_json.%s }}" % key,
            "availability_topic": STATUS,
            "device": DEVICE,
            **extra,
        }
        mqtt.publish(f"homeassistant/{component}/fort_relay/{key}/config", json.dumps(cfg), retain=True)


def main():
    increments = deque(maxlen=WINDOW)  # per-minute {key: increase}
    previous = None
    mqtt = MQTT()
    while True:
        try:
            if mqtt.sock is None:
                mqtt.connect()
                discovery(mqtt)
                mqtt.publish(STATUS, "online", retain=True)
                print("connected to MQTT", flush=True)
            up = envoy_ready()
            state = {"up": "ON" if up else "OFF", "cert_days_left": cert_days_left()}
            try:
                stats = envoy_stats()
            except Exception:
                stats = {}
            if stats:
                totals = {k: sum(stats.get(n, 0) for n in names) for k, names in COUNTERS.items()}
                if previous is not None:
                    # A counter that went down means Envoy restarted: count from zero.
                    increments.append({k: (v - previous[k]) if v >= previous[k] else v for k, v in totals.items()})
                previous = totals
            for k in COUNTERS:
                state[k] = sum(i[k] for i in increments) if stats else None
            state["active_connections"] = stats.get("listener.0.0.0.0_8443.downstream_cx_active") if stats else None
            mqtt.publish(STATE, json.dumps(state), retain=True)
            mqtt.ping()
        except Exception as e:
            print(f"error: {e!r}; reconnecting", flush=True)
            mqtt.close()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
