#!/bin/sh
# Creates your family's client CA for the Fort relay, with smallstep's `step` CLI.
#   ./new-ca.sh "Smith Fort Client CA"
# Writes fort-ca.crt (public: goes to the relay's ca/ folder) and fort-ca.key
# (private: store it offline, e.g. in a password manager, and delete it here).
set -eu
NAME=${1:?usage: ./new-ca.sh "Your Family Fort Client CA"}
command -v step >/dev/null || { echo "Install step first: https://smallstep.com/docs/step-cli/installation"; exit 1; }
[ -e fort-ca.key ] && { echo "fort-ca.key already exists; not overwriting"; exit 1; }
step certificate create "$NAME" fort-ca.crt fort-ca.key --profile root-ca --not-after 87600h
echo
echo "Done. Copy fort-ca.crt to the relay's ca/ folder. Save fort-ca.key somewhere"
echo "safe and offline (you need it only to add iPads), then delete it from here."
