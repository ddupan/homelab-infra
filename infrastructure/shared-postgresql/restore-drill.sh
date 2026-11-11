#!/usr/bin/env bash
# Restore drill: builds an empty instance with the real playbooks in a throwaway VM on the
# laptop and imports the newest off-site dump. pg-prod is not touched. Run it on the
# machine the YubiKey is plugged into (Linux or macOS), with the repo checked out:
#   infrastructure/shared-postgresql/restore-drill.sh
# One gpg decrypt (touch the YubiKey). The dump goes straight from gpg over ssh into the
# VM's tmpfs, never to disk on either side.
# KEEP=1 leaves the VM for debugging: delete it afterwards, it holds real data
# (ssh laptop bash .pg-restore-drill-host.sh down).
set -euo pipefail
cd "$(dirname "$0")"

LAPTOP="${LAPTOP:-panxiao81@192.168.10.127}"
HOST_SCRIPT=.pg-restore-drill-host.sh
host() { ssh "$LAPTOP" bash "$HOST_SCRIPT" "$@"; }

ssh "$LAPTOP" "cat > $HOST_SCRIPT" < restore-drill-host.sh
trap '[ -n "${KEEP:-}" ] || host down' EXIT

host up
host fetch | gpg -dq | host push
host restore
