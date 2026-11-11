#!/usr/bin/env bash
# Laptop side of the restore drill; restore-drill.sh / .ps1 upload this file and call it.
# Builds an empty instance with the real playbooks in a throwaway Incus VM
# (ansible/inventory/drill.yml), cuts its network, then imports the off-site dump.
# Comments stay ASCII: Windows PowerShell 5.1 mangles anything else when uploading this.
set -euo pipefail

VM=pg-restore-drill
BUCKET=pg-dump
STATE="$HOME/.pg-restore-drill"
# The repo the rebuild runs from: main as it is now, not whatever this checkout has.
TREE="${REPO_DIR:-$STATE/tree}"
# ssh does not run a login shell. A forwarded agent can be dead, which hangs ssh and ansible.
export PATH="$HOME/.local/bin:$HOME/bin:$PATH" SSH_AUTH_SOCK=

die() { echo "restore-drill: $*" >&2; exit 1; }
# </dev/null: incus exec forwards stdin, and in push() stdin is the dump being delivered.
guest() { incus exec "$VM" -- "$@" </dev/null; }

wait_agent() {
  # The Incus agent can take about 5 minutes to come up on this host.
  for _ in $(seq 1 180); do guest true 2>/dev/null && return 0; sleep 5; done
  die "$VM agent did not come up"
}

# The role signs the instance cert in Bao, which local-development may not do.
play() {
  (cd "$TREE/infrastructure/shared-postgresql" &&
    PG_BAO_SPIFFE_ROLE=homelab-postgresql python3 run.py --spiffe ansible "$@" -i inventory/drill.yml)
}

assert_isolated() {
  ! incus config show "$VM" --expanded | grep -q 'type: nic' || die "$VM still has a NIC"
  [ "$(guest ls /sys/class/net)" = lo ] || die "$VM has a network interface"
}

up() {
  # Over ssh stdin is a pipe that never closes, and incus init waits on it for YAML.
  exec </dev/null
  ! incus info "$VM" >/dev/null 2>&1 || die "$VM already exists; run 'down' first"
  if [ -z "${REPO_DIR:-}" ]; then
    rm -rf "$STATE"
    mkdir -p "$TREE"
    git -C "$HOME/services" fetch -q origin main
    git -C "$HOME/services" archive origin/main infrastructure/shared-postgresql | tar -x -C "$TREE"
  fi
  # preflight.yml wants 2 GiB for a dev instance; the dump expands to a few hundred MB.
  incus init images:ubuntu/24.04 "$VM" --vm -s ayatori -n br0 \
    -c limits.cpu=2 -c limits.memory=3GiB -c security.secureboot=false -d root,size=10GiB
  incus start "$VM"
  wait_agent
  # What a new host brings before Ansible: python (the image has none), zstd for the dump.
  # The NIC takes a moment after the agent. Flaky WAN.
  guest bash -c '
    export DEBIAN_FRONTEND=noninteractive
    for i in 1 2 3 4 5 6 7 8; do
      apt-get update -qq && apt-get install -y -qq python3 sudo zstd >/dev/null && exit 0
      sleep 30
    done
    exit 1'
  # preflight.yml refuses a data dir that is not its own mount (storage.yml makes a ZFS
  # dataset or a PVE mount point). A bind mount is enough in a VM that lives an hour.
  guest bash -c 'mkdir -p /srv/pg-dev /var/lib/homelab-postgresql/dev &&
    mount --bind /srv/pg-dev /var/lib/homelab-postgresql/dev'
  addr="$(guest ip -4 -o addr show scope global | awk '{sub("/.*", "", $4); print $4; exit}')"
  [ -n "$addr" ] || die "$VM has no IPv4 address"
  play packages.yml -e "pg_address=$addr"
  play site.yml -e "pg_address=$addr"
  play bootstrap.yml -e "pg_address=$addr" -e pg_allow_initialize=true
  # Live, not with a reboot: the bind mount would be gone.
  incus config device remove "$VM" eth0
  assert_isolated
  guest install -d -m 0755 /run/drill
  echo "$VM is built and has no network"
}

fetch() { # newest ciphertext on stdout
  latest="$(oci os object list -bn "$BUCKET" --all --query 'sort(data[].name) | [-1]' --raw-output)"
  [ -n "$latest" ] || die "bucket $BUCKET is empty"
  echo "dump: $latest" >&2
  oci os object get -bn "$BUCKET" --name "$latest" --file -
}

push() { # the decrypted dump (still zstd) on stdin
  assert_isolated
  incus file push - "$VM/run/drill/dump" --mode 0644
  guest zstd -tq /run/drill/dump || die "the dump is empty or damaged (did gpg fail?)"
}

restore() {
  exec </dev/null
  assert_isolated
  play restore-drill.yml
}

down() {
  if incus info "$VM" >/dev/null 2>&1; then
    incus delete --force "$VM"
    echo "$VM deleted, with its disk"
  fi
  rm -rf "$STATE"
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  up|fetch|push|restore|down) "$cmd" "$@" ;;
  *) die "usage: $0 up|fetch|push|restore|down" ;;
esac
