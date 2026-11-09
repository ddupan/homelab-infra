#!/usr/bin/env bash
# Restore drill: proves the newest off-site snapshot can be restored, in a throwaway
# VM on the laptop that has no network. bao1 is not touched. Run it on the machine the
# YubiKey is plugged into (Linux or macOS), with the repo checked out:
#   infrastructure/openbao/restore-drill.sh
# Three gpg decrypts (touch the YubiKey): the snapshot, the seal key, the recovery key.
# They go straight from gpg over ssh into the VM's tmpfs, never to disk on either side.
# Takes about 10 minutes. KEEP=1 leaves the VM for debugging: delete it afterwards, it
# holds real secrets (ssh laptop bash .bao-restore-drill-host.sh down).
set -euo pipefail
cd "$(dirname "$0")"

LAPTOP="${LAPTOP:-panxiao81@192.168.10.127}"
HOST_SCRIPT=.bao-restore-drill-host.sh
host() { ssh "$LAPTOP" bash "$HOST_SCRIPT" "$@"; }

ssh "$LAPTOP" "cat > $HOST_SCRIPT" < restore-drill-host.sh
trap '[ -n "${KEEP:-}" ] || host down' EXIT

host up
host fetch | gpg -dq | host push snapshot
gpg -dq tpm-seal-key.gpg | host push seal.pem
gpg -dq unseal-key.gpg | host push recovery
host restore
