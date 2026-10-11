#!/usr/bin/env bash
# Unseal bao after a restart. Run it on the machine the YubiKey is plugged into (gpg needs
# the card; a forwarded agent on the laptop is signing-only), with the repo checked out:
#   infrastructure/openbao/unseal.sh
# It decrypts unseal-key.gpg (touch the YubiKey) and posts the key to /v1/sys/unseal over
# stdin, so the key never appears in argv or the process list — which is also why this
# does not use `bao operator unseal` (2.6.1 takes the key only as an argument).
set -euo pipefail

# By hostname: the listener cert is Let's Encrypt with DNS SANs only.
BAO_ADDR="${BAO_ADDR:-https://bao.lab.ddupan.top:8200}"
KEY_FILE="${KEY_FILE:-$(cd "$(dirname "$0")" && pwd)/unseal-key.gpg}"

status() { curl -sS --max-time 10 "$BAO_ADDR/v1/sys/seal-status"; }

if ! status | grep -q '"sealed":true'; then
  echo "bao is not sealed (or not reachable):"; status; echo; exit 0
fi

key="$(gpg -dq "$KEY_FILE" | tr -d '[:space:]')"
printf '{"key":"%s"}' "$key" \
  | curl -sS --fail --max-time 10 -X PUT --data @- "$BAO_ADDR/v1/sys/unseal" >/dev/null
unset key

if status | grep -q '"sealed":false'; then
  echo "unsealed"
else
  echo "still sealed:"; status; echo; exit 1
fi
