#!/usr/bin/env bash
# Agentless Cinc: install the client over ssh if needed, push a policy archive,
# run it. There is no Cinc Server and no automatic apply; a node's own timer only
# why-runs the last policy applied here (homelab_base drift_check).
#
#   converge.sh lock <policy>                     resolve/refresh policies/<policy>.lock.json
#   converge.sh run <policy> [--why-run] <host>…  install client if needed, push, run
#
# Hosts are DNS names (lab.ddupan.top); root ssh as for the Ansible plays.
set -euo pipefail

CINC_VERSION=19.3.14          # keep equal to the workstation's client
WORKSTATION=docker.io/cincproject/workstation:26.3.0
NODE_DIR=/var/lib/homelab-cinc  # policy/ = last applied; shared with homelab_base
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/homelab-cinc
SSH=(ssh -o BatchMode=yes)

workstation() {
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$HERE/policies:/p" -v "$WORK:/out" -w /p \
    "$WORKSTATION" "$@"
}

# The WAN drops at random (see CLAUDE.md); everything fetched from it retries.
retry() { local i; for i in 1 2 3 4 5; do "$@" && return; sleep 10; done; return 1; }

ensure_client() {
  local host=$1 have id ver arch meta url sha deb
  have=$("${SSH[@]}" "root@$host" "dpkg-query -W -f='\${Version}' cinc 2>/dev/null || true")
  [[ $have == "$CINC_VERSION-1" ]] && return
  read -r id ver arch < <("${SSH[@]}" "root@$host" '. /etc/os-release; echo "$ID" "$VERSION_ID" "$(uname -m)"')
  # Official per-package sha256 from omnitruck; no hard-coded checksums.
  meta=$(retry curl -fsS --max-time 30 \
    "https://omnitruck.cinc.sh/stable/cinc/metadata?p=$id&pv=$ver&m=$arch&v=$CINC_VERSION")
  url=$(awk '$1 == "url" {print $2}' <<<"$meta")
  sha=$(awk '$1 == "sha256" {print $2}' <<<"$meta")
  [[ $url && $sha ]] || { echo "no cinc $CINC_VERSION for $id $ver $arch" >&2; return 1; }
  # Downloaded on the laptop and copied, so nodes need no internet access.
  deb=$CACHE/${url##*/}
  mkdir -p "$CACHE"
  if ! sha256sum -c --status <<<"$sha  $deb" 2>/dev/null; then
    retry curl -fsSL --max-time 600 -o "$deb.part" "$url"
    sha256sum -c --quiet <<<"$sha  $deb.part"
    mv "$deb.part" "$deb"
  fi
  echo "==> $host: installing cinc $CINC_VERSION (had: ${have:-none})"
  scp -q -o BatchMode=yes "$deb" "root@$host:/tmp/${deb##*/}"
  "${SSH[@]}" "root@$host" "dpkg -i /tmp/${deb##*/} >/dev/null && rm -f /tmp/${deb##*/}"
}

cmd=${1:-}; policy=${2:-}
[[ $cmd && $policy && -f $HERE/policies/$policy.rb ]] || { sed -n '6,9p' "$0" >&2; exit 2; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

if [[ $cmd == lock ]]; then
  workstation cinc install "$policy.rb" >/dev/null
  exec git -C "$HERE" status --short "policies/$policy.lock.json"
fi
[[ $cmd == run ]] || { sed -n '6,9p' "$0" >&2; exit 2; }
shift 2
mode=apply; [[ ${1:-} == --why-run ]] && { mode=why-run; shift; }
(( $# )) || { echo "no hosts" >&2; exit 2; }
[[ -f $HERE/policies/$policy.lock.json ]] || { echo "no lock: converge.sh lock $policy" >&2; exit 2; }

# From the committed lock only: with a lock present, `cinc install` just fetches
# the pinned revisions into the (fresh, per-container) cache; it never re-resolves.
workstation bash -c "cinc install '$policy.rb' >/dev/null && cinc export '$policy.rb' /out --archive >/dev/null"
archive=$(ls "$WORK"/*.tgz)

for host in "$@"; do
  ensure_client "$host"
  echo "==> $host: $mode $(basename "$archive")"
  scp -q -o BatchMode=yes "$archive" "root@$host:/tmp/homelab-cinc-policy.tgz"
  # Apply runs in a staging dir and only replaces policy/ after success, so the
  # drift timer always compares against what was really applied. why-run never
  # replaces it.
  "${SSH[@]}" "root@$host" bash -s -- "$mode" "$NODE_DIR" <<'REMOTE'
set -euo pipefail
mode=$1 dir=$2 stage=$2/staging
mkdir -p "$dir" && rm -rf "$stage" && mkdir "$stage"
tar -xzf /tmp/homelab-cinc-policy.tgz -C "$stage" && rm -f /tmp/homelab-cinc-policy.tgz
cd "$stage"
if [[ $mode == why-run ]]; then
  rc=0; /opt/cinc/bin/cinc-client -z --why-run --no-color || rc=$?
  rm -rf "$stage"; exit $rc
fi
/opt/cinc/bin/cinc-client -z --no-color
cd / && rm -rf "$dir/previous" && { [[ -d $dir/policy ]] && mv "$dir/policy" "$dir/previous" || true; }
mv "$stage" "$dir/policy"
# Refresh the drift metric now, not at the next daily run: drift detected before
# this apply would otherwise keep alerting for up to a day after it was fixed.
systemctl start homelab-cinc-drift.service
REMOTE
done
