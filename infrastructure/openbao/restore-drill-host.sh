#!/usr/bin/env bash
# Laptop side of the restore drill; restore-drill.sh / .ps1 upload this file and call it.
# Never touches bao1 beyond reading its binaries. Everything runs in a throwaway Incus VM
# with a vTPM and, by the time any secret arrives, no network: a restored bao holds real
# leases and would try to revoke them against real backends.
# Comments stay ASCII: Windows PowerShell 5.1 mangles anything else when uploading this.
set -euo pipefail

VM="${VM:-bao-restore-drill}"
BAO1=ansible@192.168.10.8
BUCKET=bao-snapshot
# The user's forwarded agent can be dead, which hangs ssh; ~/.ssh keys work without it.
export SSH_AUTH_SOCK=
OCI="$(command -v oci || echo "$HOME/bin/oci")"

die() { echo "restore-drill: $*" >&2; exit 1; }
# </dev/null: incus exec forwards stdin, and in push() stdin is the secret being delivered.
guest() { incus exec "$VM" -- "$@" </dev/null; }

wait_agent() {
  # The Incus agent can take about 5 minutes to come up on this host.
  for _ in $(seq 1 180); do guest true 2>/dev/null && return 0; sleep 5; done
  die "$VM agent did not come up"
}

assert_isolated() {
  ! incus config show "$VM" --expanded | grep -q 'type: nic' || die "$VM still has a NIC"
  [ "$(guest ls /sys/class/net)" = lo ] || die "$VM has a network interface"
}

from_bao1() { # remote path, guest path, mode
  ssh -o BatchMode=yes "$BAO1" sudo -n cat "$1" | incus file push - "$VM$2" --mode "$3"
}

up() {
  # Over ssh stdin is a pipe that never closes, and incus init waits on it for YAML.
  exec </dev/null
  ! incus info "$VM" >/dev/null 2>&1 || die "$VM already exists; run 'down' first"
  # Not the /cloud image: as an Incus VM it reboot-loops at cloud-init on this host.
  incus init images:ubuntu/24.04 "$VM" --vm -s ayatori -n br0 \
    -c limits.cpu=2 -c limits.memory=2GiB -c security.secureboot=false -d root,size=8GiB
  incus config device add "$VM" vtpm tpm path=/dev/tpm0 pathrm=/dev/tpmrm0
  incus start "$VM"
  wait_agent

  guest bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # Flaky WAN, and the NIC takes a moment after the agent.
    for i in 1 2 3 4 5 6 7 8; do
      apt-get update -qq && apt-get install -y -qq \
        libtpm2-pkcs11-1 libtpm2-pkcs11-tools jq openssl curl >/dev/null && exit 0
      sleep 30
    done
    exit 1'
  guest bash -c '
    set -e
    useradd --system --no-create-home --groups tss openbao
    install -d -o root -g root -m 0755 /etc/openbao /opt/openbao/plugins
    install -d -o openbao -g openbao -m 0700 /opt/openbao/data /opt/openbao/tpm2-pkcs11'

  # The same build bao1 runs, so a pass says something about what is in production.
  from_bao1 /usr/local/bin/bao /usr/local/bin/bao 0755
  from_bao1 /opt/openbao/plugins/openbao-plugin-kms-pkcs11 /opt/openbao/plugins/openbao-plugin-kms-pkcs11 0755
  from_bao1 /etc/openbao/tpm-seal.pub /etc/openbao/tpm-seal.pub 0644

  incus stop "$VM"
  incus config device remove "$VM" eth0
  incus start "$VM"
  wait_agent
  assert_isolated
  guest install -d -m 0755 /run/drill
  echo "$VM is up with no network"
}

fetch() { # newest ciphertext on stdout
  latest="$("$OCI" os object list -bn "$BUCKET" --all --query 'sort(data[].name) | [-1]' --raw-output)"
  [ -n "$latest" ] || die "bucket $BUCKET is empty"
  echo "snapshot: $latest" >&2
  "$OCI" os object get -bn "$BUCKET" --name "$latest" --file -
}

push() { # snapshot | seal.pem | recovery, on stdin
  case "${1:-}" in snapshot|seal.pem|recovery) ;; *) die "cannot push '${1:-}'" ;; esac
  assert_isolated
  incus file push - "$VM/run/drill/$1" --mode 0600
  guest test -s "/run/drill/$1" || die "$1 arrived empty (did gpg fail?)"
}

restore() {
  assert_isolated
  incus exec "$VM" -- bash -s <<'INNER'
set -euo pipefail
d=/run/drill cfg=/etc/openbao store=/opt/openbao/tpm2-pkcs11
export BAO_ADDR=http://127.0.0.1:8200
trap 'rc=$?; [ "$rc" -eq 0 ] || tail -n 25 "$d/bao.log" >&2 || true' EXIT

start() { setsid runuser -u openbao -- bao server -config="$cfg/config.hcl" >>"$d/bao.log" 2>&1 </dev/null & }
seal_status() { curl -s --max-time 5 "$BAO_ADDR/v1/sys/seal-status" || true; }
wait_for() { # jq filter over seal-status
  for _ in $(seq 1 90); do seal_status | jq -e "$1" >/dev/null 2>&1 && return 0; sleep 2; done
  echo "timed out waiting for $1" >&2; exit 1
}

# The wrong key would import fine and then never unwrap the root key.
openssl pkey -in "$d/seal.pem" -pubout | cmp - "$cfg/tpm-seal.pub"
echo "seal key matches tpm-seal.pub"

pin=$(openssl rand -hex 16)
sopin=$(openssl rand -hex 16)
chown openbao "$d/seal.pem"
p11() { runuser -u openbao -- env TPM2_PKCS11_STORE="$store" tpm2_ptool "$@" >/dev/null; }
p11 init
p11 addtoken --pid=1 --label=openbao --sopin="$sopin" --userpin="$pin"
p11 import --label=openbao --key-label=bao-seal --userpin="$pin" --privkey="$d/seal.pem" --algorithm=rsa
shred -u "$d/seal.pem"

plugin_sha=$(sha256sum /opt/openbao/plugins/openbao-plugin-kms-pkcs11 | cut -d' ' -f1)
# node_id must be bao1's: the snapshot's Raft configuration names it as the only voter.
cat > "$cfg/config.hcl" <<EOF
disable_mlock    = true
plugin_directory = "/opt/openbao/plugins"
api_addr         = "http://127.0.0.1:8200"
cluster_addr     = "https://127.0.0.1:8201"
storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "bao1"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
  # Off by default since 2.5.3. Safe here: loopback in a VM with no network.
  disable_unauthed_generate_root_endpoints = false
}
plugin "kms" "pkcs11" {
  command   = "openbao-plugin-kms-pkcs11"
  sha256sum = "$plugin_sha"
  env       = ["TPM2_PKCS11_STORE=$store"]
}
seal "pkcs11" {
  lib           = "/usr/lib/x86_64-linux-gnu/pkcs11/libtpm2_pkcs11.so"
  token_label   = "openbao"
  pin           = "$pin"
  key_label     = "bao-seal"
  mechanism     = "CKM_RSA_PKCS_OAEP"
  rsa_oaep_hash = "sha256"
}
EOF
chown root:openbao "$cfg/config.hcl"
chmod 0640 "$cfg/config.hcl"
unset pin sopin

start
wait_for '.initialized == false'
# Restore needs a running cluster to restore into. Its token dies with the restore.
BAO_TOKEN=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json | jq -r .root_token)
export BAO_TOKEN
wait_for '.sealed == false'
for _ in $(seq 1 30); do bao operator raft list-peers >/dev/null 2>&1 && break; sleep 2; done
bao operator raft snapshot restore -force "$d/snapshot"
unset BAO_TOKEN
wait_for '.sealed == false'
echo "snapshot restored and unsealed"

# The actual claim: restored data comes back on its own from the imported seal key.
pkill -x bao
while pgrep -x bao >/dev/null; do sleep 1; done
start
wait_for '.initialized == true and .sealed == false'
echo "unsealed by itself after a restart"

# Getting a token through the recovery key proves that path too, and does not depend on
# any token in the snapshot still being valid. It only ever exists inside this VM.
curl -s -X DELETE "$BAO_ADDR/v1/sys/generate-root/attempt" >/dev/null
attempt=$(curl -sf -X PUT -d '{}' "$BAO_ADDR/v1/sys/generate-root/attempt")
[ "$(jq -r .required <<<"$attempt")" = 1 ] || { echo "expected one recovery share" >&2; exit 1; }
otp=$(jq -r .otp <<<"$attempt")
encoded=$(jq -n --rawfile k "$d/recovery" --arg n "$(jq -r .nonce <<<"$attempt")" \
    '{key: ($k | gsub("\\s"; "")), nonce: $n}' \
  | curl -sf -X PUT --data @- "$BAO_ADDR/v1/sys/generate-root/update" | jq -r .encoded_token)
# Not `bao operator generate-root -decode`: since 2.6 it first calls the authenticated
# endpoint, and there is no token yet. The encoding is a plain XOR with the OTP.
BAO_TOKEN=$(ENCODED="$encoded" OTP="$otp" python3 -c '
import base64, os
e = os.environ["ENCODED"]
raw = base64.b64decode(e + "=" * (-len(e) % 4), altchars=b"-_")
print(bytes(a ^ b for a, b in zip(raw, os.environ["OTP"].encode())).decode())')
export BAO_TOKEN
echo "root token generated with the recovery key"

# Names and counts only: the values are real secrets.
seal_status | jq -c '{type, recovery_seal, sealed, version}'
echo "mounts: $(bao secrets list -format=json | jq -c 'keys')"
echo "auth:   $(bao auth list -format=json | jq -c 'keys')"
total=0
item=
for prefix in $(bao kv list -format=json -mount=kv | jq -r '.[]'); do
  case "$prefix" in
    */)
      list=$(bao kv list -format=json -mount=kv "$prefix")
      n=$(jq length <<<"$list"); total=$((total + n)); echo "kv/$prefix: $n"
      [ -n "$item" ] || item=$(jq -r --arg p "$prefix" 'first(.[] | select(endswith("/") | not) | $p + .) // empty' <<<"$list")
      ;;
    *) total=$((total + 1)) ;;
  esac
done
[ "$total" -gt 0 ] || { echo "kv is empty" >&2; exit 1; }
[ -n "$item" ] || { echo "no readable kv entry found" >&2; exit 1; }
echo "kv/$item fields: $(bao kv get -format=json -mount=kv "$item" | jq -c '.data.data | keys')"
if bao secrets list -format=json | jq -e 'has("pki/")' >/dev/null; then
  curl -sf "$BAO_ADDR/v1/pki/ca/pem" | openssl x509 -noout -subject -enddate
fi
echo "DRILL PASSED"
INNER
}

down() {
  incus info "$VM" >/dev/null 2>&1 || exit 0
  incus delete --force "$VM"
  echo "$VM deleted, with its disk and vTPM"
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  up|fetch|push|restore|down) "$cmd" "$@" ;;
  *) die "usage: $0 up|fetch|push <name>|restore|down" ;;
esac
