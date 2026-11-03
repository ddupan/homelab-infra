#!/bin/bash
# Run renew-etcd-cert.yml with a 15-minute Bao token from the local SPIFFE
# identity; the token lives only in this process and is revoked on exit.
set -euo pipefail
export BAO_ADDR=${BAO_ADDR:-https://bao.lab.ddupan.top:8200}
jwt=$(spire-agent api fetch jwt -audience openbao \
  -socketPath /run/spire/agent-sockets/spire-agent.sock -output json | jq -er '.[0].svids[0].svid')
BAO_TOKEN=$(bao write -field=token auth/jwt-spire/login role=homelab-sandbox-postgresql jwt="$jwt")
export BAO_TOKEN
trap 'bao token revoke -self >/dev/null || echo "token revoke failed; it expires with its TTL" >&2' EXIT
cd "$(dirname "$0")/ansible"
ansible-playbook renew-etcd-cert.yml "$@"
