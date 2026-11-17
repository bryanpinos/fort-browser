# Page review

A local AI model reads the pages your kids visit (address, title and the first part of the text), labels each one, and tells you about anything worrying, with a short daily summary. Needs [the relay](relay.md). Nothing goes to any cloud service.

## What you need
- An OpenAI-compatible model server on your network, e.g. [LM Studio](https://lmstudio.ai/) with "Serve on Local Network" on. We use **Gemma 4 31B** (`gemma-4-31b-it`); any capable instruction model works.
- Optional: Home Assistant with an MQTT broker, for alerts and sensors.

## Turn it on
1. In the relay's `.env`: add `review` (and `monitoring` if you like) to `COMPOSE_PROFILES`, set `LLM_URL`, `LLM_MODEL`, `MQTT_HOST`, and optionally `REVIEW_SUMMARY_AT` (daily summary time) and `REVIEW_RETENTION_DAYS`.
2. `docker compose up -d`.
3. Turn on **page review** per iPad (Parent settings › *Send page text home for review*) or for all of them from [home config](home-config.md) (`"reviewPages": true`).

## What you get
- Each page gets a category (ok, adult, violence, self-harm, drugs and alcohol, hate, gambling and scams, other mature) and a concern level 0–3 with a one-line summary.
- In Home Assistant (MQTT discovery): per iPad, *pages today* and *flagged today* sensors, and an event entity with `flagged` (concern 2 or more) and `daily_summary` events to build notifications on.
- In [Fort Parent](parent-console.md): every visit, block and flag per kid.

## Privacy
Page text and titles are deleted after `REVIEW_RETENTION_DAYS` (default 30); visit records after a year. The data stays in `server/relay/review/` on your server.
