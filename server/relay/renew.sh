#!/bin/sh
# Issue/renew the relay.example.com cert once a day (lego only renews when due),
# then hand Envoy (uid 65532) a readable copy via atomic rename so its
# watched_directory picks up renewals without a restart.
set -u
: "${LEGO_EMAIL:?set LEGO_EMAIL in .env}"
D=relay.example.com
while true; do
  if /lego run --path /data --accept-tos --email "$LEGO_EMAIL" \
       --key-type ec256 --dns route53 --dns.propagation.wait 45s --domains $D; then
    echo "$(date -Iseconds) lego ok"
  else
    echo "$(date -Iseconds) lego FAILED"
  fi
  if [ -s /data/certificates/$D.crt ] && [ -s /data/certificates/$D.key ]; then
    install -o 65532 -g 65532 -m 0400 /data/certificates/$D.key /out/.relay.key.tmp && mv -f /out/.relay.key.tmp /out/relay.key
    install -o 65532 -g 65532 -m 0444 /data/certificates/$D.crt /out/.relay.crt.tmp && mv -f /out/.relay.crt.tmp /out/relay.crt
  fi
  sleep 86400
done
