#!/usr/bin/env bash
# Laptop side of the restore drill; restore-drill.sh / .ps1 upload this file and call it.
# Drives the real playbooks against a throwaway Incus VM (ansible/inventory/drill.yml).
# Comments stay ASCII: Windows PowerShell 5.1 mangles anything else when uploading this.
set -euo pipefail

VM=bao-restore-drill
BUCKET=bao-snapshot
STATE="$HOME/.bao-restore-drill"
# The repo the rebuild runs from: main as it is now, not whatever this checkout has.
TREE="${REPO_DIR:-$STATE/tree}"
# ssh does not run a login shell. A forwarded agent can be dead, which hangs ssh and ansible.
export PATH="$HOME/.local/bin:$HOME/bin:$PATH" SSH_AUTH_SOCK=

die() { echo "restore-drill: $*" >&2; exit 1; }
# </dev/null: incus exec forwards stdin, and in push() stdin is the secret being delivered.
guest() { incus exec "$VM" -- "$@" </dev/null; }

wait_agent() {
  # The Incus agent can take about 5 minutes to come up on this host.
  for _ in $(seq 1 180); do guest true 2>/dev/null && return 0; sleep 5; done
  die "$VM agent did not come up"
}

play() { (cd "$TREE/infrastructure/openbao/ansible" && ansible-playbook -i inventory/drill.yml "$@"); }

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
    git -C "$HOME/services" archive origin/main infrastructure/openbao | tar -x -C "$TREE"
    ln -s "$HOME/services/.vault_pass" "$TREE/.vault_pass"
  fi
  # Not the /cloud image: as an Incus VM it reboot-loops at cloud-init on this host.
  incus init images:ubuntu/24.04 "$VM" --vm -s ayatori -n br0 \
    -c limits.cpu=2 -c limits.memory=2GiB -c security.secureboot=false -d root,size=8GiB
  incus config device add "$VM" vtpm tpm path=/dev/tpm0 pathrm=/dev/tpmrm0
  incus start "$VM"
  wait_agent
  # The image has no python, and the NIC takes a moment after the agent. Flaky WAN.
  guest bash -c '
    export DEBIAN_FRONTEND=noninteractive
    for i in 1 2 3 4 5 6 7 8; do
      apt-get update -qq && apt-get install -y -qq python3 >/dev/null && exit 0
      sleep 30
    done
    exit 1'
  # The seal goes on after tpm-seal.yml, as on a new node: the role refuses it before.
  play provision-openbao.yml -e '{"openbao_pkcs11_seal": false}'
}

seal() { # the escrowed seal key PEM on stdin
  incus file push - "$VM/run/tpm-seal.pem" --mode 0600
  guest test -s /run/tpm-seal.pem || die "the seal key arrived empty (did gpg fail?)"
  exec </dev/null
  play tpm-seal.yml -e openbao_pkcs11_import_key=/run/tpm-seal.pem
  play provision-openbao.yml
  # Live, not with a reboot: the unit requires network-online.target.
  incus config device remove "$VM" eth0
  assert_isolated
  guest install -d -m 0755 /run/drill
  echo "$VM is rebuilt and has no network"
}

fetch() { # newest ciphertext on stdout
  latest="$(oci os object list -bn "$BUCKET" --all --query 'sort(data[].name) | [-1]' --raw-output)"
  [ -n "$latest" ] || die "bucket $BUCKET is empty"
  echo "snapshot: $latest" >&2
  oci os object get -bn "$BUCKET" --name "$latest" --file -
}

push() { # snapshot | recovery, on stdin
  case "${1:-}" in snapshot|recovery) ;; *) die "cannot push '${1:-}'" ;; esac
  assert_isolated
  incus file push - "$VM/run/drill/$1" --mode 0600
  guest test -s "/run/drill/$1" || die "$1 arrived empty (did gpg fail?)"
}

restore() {
  exec </dev/null
  assert_isolated
  play restore-drill.yml
}

down() {
  if incus info "$VM" >/dev/null 2>&1; then
    incus delete --force "$VM"
    echo "$VM deleted, with its disk and vTPM"
  fi
  rm -rf "$STATE"
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  up|seal|fetch|push|restore|down) "$cmd" "$@" ;;
  *) die "usage: $0 up|seal|fetch|push <name>|restore|down" ;;
esac
