#!/bin/sh
# Issues a client certificate for one iPad, packaged the way iOS can import it.
#   ./new-device.sh example.com kid1-ipad "Ava's iPad"
# Needs fort-ca.crt and fort-ca.key here. Writes <id>.p12 (you choose its
# password); import it in Fort's Parent settings, then delete it.
# The device's identity is spiffe://<trust domain>/fort/device/<id>: add that
# exact line to the relay's clients/clients.yaml.
set -eu
DOMAIN=${1:?usage: ./new-device.sh <trust domain, e.g. example.com> <device-id> "<name>"}
ID=${2:?device id, e.g. kid1-ipad (letters, digits, . _ -)}
NAME=${3:-$ID}
case $ID in *[!A-Za-z0-9._-]*) echo "device id may only use letters, digits, . _ -"; exit 1;; esac
[ -e fort-ca.crt ] && [ -e fort-ca.key ] || { echo "fort-ca.crt and fort-ca.key must be here"; exit 1; }
DIR=$(cd "$(dirname "$0")" && pwd)
step certificate create "$NAME" "$ID.crt" "$ID.key" --template "$DIR/device.tpl" \
  --san "spiffe://$DOMAIN/fort/device/$ID" --ca fort-ca.crt --ca-key fort-ca.key \
  --not-after 17520h --no-password --insecure
# --legacy: iOS can only import PKCS#12 files with the older encryption.
step certificate p12 --legacy --ca fort-ca.crt "$ID.p12" "$ID.crt" "$ID.key"
rm -f "$ID.key" "$ID.crt"
echo
echo "Wrote $ID.p12. Add to the relay's clients/clients.yaml:"
echo "    - san_type: URI"
echo "      matcher: {exact: \"spiffe://$DOMAIN/fort/device/$ID\"}"
echo "Then AirDrop $ID.p12 to the iPad inside a zip, import it in Fort, and delete the copies."
