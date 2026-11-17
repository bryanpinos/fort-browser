"""Fort review worker: classifies pages queued by fort-ingest with Gemma and
reports to Home Assistant over MQTT.

Runs on an ordinary docker network (NOT the isolated relay network) because it
must reach LM Studio and MQTT on the LAN. It shares only the SQLite queue
(/data/review.db) with fort-ingest. Standard library only.

Never in the browsing path: if Gemma is down, pages simply wait in the queue.
"""
import json
import os
import re
import socket
import sqlite3
import struct
import time
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone

DB = os.environ.get("REVIEW_DB", "/data/review.db")
LLM_URL = os.environ.get("LLM_URL", "http://192.168.1.20:1234/v1/chat/completions")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemma-4-31b-it")
MQTT_HOST = os.environ.get("MQTT_HOST", "192.168.1.10")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
SUMMARY_AT = os.environ.get("SUMMARY_AT", "19:30")  # local time (host /etc/localtime)
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
ALERT_CONCERN = 2  # concern >= this sends an alert

PREFIX = "fort_review"
STATUS, STATS, EVENT = f"{PREFIX}/status", f"{PREFIX}/stats", f"{PREFIX}/event"
DEVICE = {"identifiers": ["fort_review"], "name": "Fort review", "manufacturer": "Fort", "model": "Page review (Gemma)"}
CATEGORIES = ["ok", "adult", "violence", "self_harm", "drugs_alcohol", "hate", "gambling_scams", "mature_other"]

PROMPT = """You help a parent review web pages their child (about 9 years old) viewed in a supervised browser.
Judge the page from its address, title and visible text. Reply with ONLY a JSON object:
{"category": one of %s,
 "concern": 0-3 (0 = fine for a 9-year-old, 1 = mildly mature, 2 = a parent should know, 3 = urgent: sexual content, self-harm, contact from strangers, grooming),
 "summary": "neutral description in at most 20 words"}
Ordinary news, games, school, shopping and video sites are usually 0 or 1. Do not flag a page just for ads.""" % CATEGORIES


# --- minimal MQTT 3.1.1 (QoS 0), same as fort-relay-monitor ---------------

def _varint(n):
    out = bytearray()
    while True:
        b, n = n % 128, n // 128
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
        body = _str("MQTT") + bytes([4, 0x02 | 0x04 | 0x20]) + struct.pack("!H", 300) \
            + _str("fort-review-worker") + _str(STATUS) + _str("offline")
        s.sendall(bytes([0x10]) + _varint(len(body)) + body)
        ack = s.recv(4)
        if len(ack) < 4 or ack[0] != 0x20 or ack[3] != 0:
            raise ConnectionError(f"CONNACK refused: {ack!r}")
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


# --- storage ------------------------------------------------------------------

def connect():
    db = sqlite3.connect(DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=10000")
    db.row_factory = sqlite3.Row
    return db


def local_midnight_utc():
    now = datetime.now().astimezone()
    return now.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc).isoformat(timespec="seconds")


# --- classification -----------------------------------------------------------

class BadAnswer(Exception):
    """The LLM answered, but not with usable JSON (don't back off for this)."""


# LM Studio enforces this schema (structured output), so Gemma can't return
# malformed JSON; parse_verdict below is only a fallback.
SCHEMA = {
    "name": "page_verdict",
    "strict": True,
    "schema": {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": CATEGORIES},
            "concern": {"type": "integer", "minimum": 0, "maximum": 3},
            "summary": {"type": "string"},
        },
        "required": ["category", "concern", "summary"],
        "additionalProperties": False,
    },
}


def parse_verdict(content):
    # Gemma often wraps JSON in a ```json fence: take the outermost {...};
    # tolerate trailing commas.
    m = re.search(r"\{.*\}", content, re.S)
    if not m:
        raise BadAnswer(f"no JSON object in {content[:80]!r}")
    try:
        return json.loads(re.sub(r",\s*([}\]])", r"\1", m.group(0)))
    except ValueError as e:
        raise BadAnswer(f"{e}: {content[:80]!r}")


def classify(row):
    page = f"Address: {row['url']}\nTitle: {row['title'] or ''}\nVisible text: {row['text'] or ''}"
    req = urllib.request.Request(LLM_URL, method="POST", headers={"Content-Type": "application/json"}, data=json.dumps({
        "model": LLM_MODEL,
        "temperature": 0,
        "max_tokens": 200,
        "response_format": {"type": "json_schema", "json_schema": SCHEMA},
        "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": page}],
    }).encode())
    with urllib.request.urlopen(req, timeout=120) as r:
        content = json.load(r)["choices"][0]["message"]["content"]
    verdict = parse_verdict(content)
    category = verdict.get("category") if verdict.get("category") in CATEGORIES else "mature_other"
    try:
        concern = max(0, min(3, int(verdict.get("concern", 1))))
    except (TypeError, ValueError):
        concern = 1
    return category, concern, str(verdict.get("summary", ""))[:200]


def classify_pending(db, mqtt):
    """Classify a few pending pages. Returns False if the LLM is unreachable."""
    # Fewest attempts first, so one stubborn page can't block the queue.
    rows = db.execute("SELECT * FROM events WHERE status='pending' ORDER BY attempts, id LIMIT 5").fetchall()
    for row in rows:
        try:
            category, concern, summary = classify(row)
        except BadAnswer as e:
            db.execute("UPDATE events SET attempts = attempts + 1, status = CASE WHEN attempts >= 2 THEN 'failed' ELSE status END"
                       " WHERE id=?", (row["id"],))
            db.commit()
            print(f"unusable answer for #{row['id']}: {e}", flush=True)
            continue
        except Exception as e:
            db.execute("UPDATE events SET attempts = attempts + 1, status = CASE WHEN attempts >= 9 THEN 'failed' ELSE status END"
                       " WHERE id=?", (row["id"],))
            db.commit()
            print(f"classify failed for #{row['id']}: {e!r}", flush=True)
            return False
        db.execute("UPDATE events SET status='done', category=?, concern=?, summary=?, classified=? WHERE id=?",
                   (category, concern, summary, datetime.now(timezone.utc).isoformat(timespec="seconds"), row["id"]))
        db.commit()
        if concern >= ALERT_CONCERN and mqtt.sock:
            mqtt.publish(EVENT, json.dumps({
                "event_type": "flagged", "device": row["device"], "concern": concern, "category": category,
                "summary": summary, "url": row["url"], "title": row["title"], "ts": row["ts"]}))
            print(f"flagged #{row['id']} {row['device']} concern={concern} {category}", flush=True)
    return True


# --- Home Assistant -----------------------------------------------------------

def slug(device):
    return re.sub(r"[^a-z0-9]+", "_", device.lower()).strip("_")


def discovery(mqtt, devices, announced):
    if "event" not in announced:
        mqtt.publish("homeassistant/event/fort_review/alert/config", json.dumps({
            "name": "Fort review", "unique_id": "fort_review_event", "object_id": "fort_review",
            "state_topic": EVENT, "event_types": ["flagged", "daily_summary"],
            "availability_topic": STATUS, "device": DEVICE}), retain=True)
        announced.add("event")
    for d in devices:
        if d in announced:
            continue
        for key, label, icon in (("pages", "pages today", "mdi:web"), ("flagged", "flagged today", "mdi:flag")):
            mqtt.publish(f"homeassistant/sensor/fort_review/{slug(d)}_{key}/config", json.dumps({
                "name": f"{d} {label}", "unique_id": f"fort_review_{slug(d)}_{key}",
                "object_id": f"fort_review_{slug(d)}_{key}", "state_topic": STATS,
                # An iPad with no pages yet today is missing from STATS: look up
                # both levels with .get so it reads 0 instead of erroring in HA.
                "value_template": "{{ value_json.get('%s', {}).get('%s', 0) }}" % (d, key),
                "unit_of_measurement": "pages", "state_class": "total", "icon": icon,
                "availability_topic": STATUS, "device": DEVICE}), retain=True)
        announced.add(d)


def today_stats(db):
    since = local_midnight_utc()
    stats = {}
    for row in db.execute("SELECT device, kind, concern FROM events WHERE ts >= ?", (since,)):
        s = stats.setdefault(row["device"], {"pages": 0, "flagged": 0})
        if row["kind"] == "nav":
            s["pages"] += 1
        if (row["concern"] or 0) >= ALERT_CONCERN:
            s["flagged"] += 1
    return stats


def daily_summary(db, mqtt):
    since = local_midnight_utc()
    for device in [r[0] for r in db.execute("SELECT DISTINCT device FROM events WHERE ts >= ?", (since,))]:
        navs = db.execute("SELECT host, allowed FROM events WHERE device=? AND ts>=? AND kind='nav'", (device, since)).fetchall()
        flagged = db.execute("SELECT category, summary, host FROM events WHERE device=? AND ts>=? AND concern>=? ORDER BY concern DESC",
                             (device, since, ALERT_CONCERN)).fetchall()
        hosts = Counter(r["host"] for r in navs if r["allowed"])
        top = ", ".join(f"{h} ({n})" for h, n in hosts.most_common(5)) or "none"
        blocked = sum(1 for r in navs if not r["allowed"])
        lines = [f"{len(navs)} pages; top: {top}."]
        if blocked:
            lines.append(f"{blocked} blocked.")
        lines.append(f"{len(flagged)} flagged" + (": " + "; ".join(f"{r['category']} ({r['host']})" for r in flagged[:3]) if flagged else "."))
        mqtt.publish(EVENT, json.dumps({"event_type": "daily_summary", "device": device, "message": " ".join(lines),
                                        "pages": len(navs), "flagged": len(flagged)}))


def purge(db):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)).isoformat(timespec="seconds")
    db.execute("UPDATE events SET text=NULL, title=NULL WHERE ts < ? AND (text IS NOT NULL OR title IS NOT NULL)", (cutoff,))
    db.execute("DELETE FROM events WHERE ts < ?", ((datetime.now(timezone.utc) - timedelta(days=365)).isoformat(),))
    db.commit()


def main():
    while not os.path.exists(DB):
        print("waiting for fort-ingest to create the database", flush=True)
        time.sleep(10)
    mqtt, announced, last_purge = MQTT(), set(), 0
    now = datetime.now().astimezone()
    # Started after today's summary time: don't send a partial-day summary now.
    last_summary = now.date() if now.strftime("%H:%M") >= SUMMARY_AT else None
    backoff = 0
    while True:
        try:
            if mqtt.sock is None:
                mqtt.connect()
                announced.clear()
                mqtt.publish(STATUS, "online", retain=True)
                print("connected to MQTT", flush=True)
            with connect() as db:
                if time.time() >= backoff:
                    if not classify_pending(db, mqtt):
                        backoff = time.time() + 120  # LLM down: retry in 2 min
                stats = today_stats(db)
                # Announce every iPad ever seen, not just today's: otherwise an iPad
                # with nothing yet today keeps a stale sensor config in HA.
                known = [r[0] for r in db.execute("SELECT DISTINCT device FROM events")]
                discovery(mqtt, sorted(set(known) | set(stats.keys())), announced)
                mqtt.publish(STATS, json.dumps(stats), retain=True)
                now = datetime.now().astimezone()
                if now.strftime("%H:%M") >= SUMMARY_AT and last_summary != now.date():
                    daily_summary(db, mqtt)
                    last_summary = now.date()
                if time.time() - last_purge > 3600:
                    purge(db)
                    last_purge = time.time()
            mqtt.ping()
        except Exception as e:
            print(f"error: {e!r}; reconnecting", flush=True)
            mqtt.close()
        time.sleep(10)


if __name__ == "__main__":
    main()
