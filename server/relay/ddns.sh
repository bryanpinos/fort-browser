#!/bin/bash
# Keep RELAY_DOMAIN pointed at this home's public IPv4 (Route 53 A record).
# Touches only that one record, and only when the IP actually changes.
set -u
NAME=${RELAY_DOMAIN:?set RELAY_DOMAIN in .env}
ZONE=${AWS_HOSTED_ZONE_ID:?}
private='^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
while true; do
  ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
  if [[ ! $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ $ip =~ $private ]]; then
    echo "$(date -Is) no usable public IPv4 from checkip; skipping"
  else
    cur=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" --start-record-name "$NAME" \
          --start-record-type A --max-items 1 \
          --query "ResourceRecordSets[?Name=='$NAME.' && Type=='A'].ResourceRecords[0].Value" --output text 2>/dev/null)
    if [[ $cur != "$ip" ]]; then
      if aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch \
           "{\"Comment\":\"fort-relay ddns\",\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$NAME\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$ip\"}]}}]}" >/dev/null; then
        echo "$(date -Is) updated $NAME (was ${cur:-none})"
      else
        echo "$(date -Is) Route 53 update FAILED"
      fi
    fi
  fi
  sleep 300
done
