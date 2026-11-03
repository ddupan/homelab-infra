#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Push Cinc policies to nodes and converge them, in parallel, with streamed logs.

    ./converge.py --why-run                    preview every node (changes nothing)
    ./converge.py -l etcd-pve1                 apply one node (short name, FQDN or policy)
    ./converge.py -l loadbalancer-prod -i KEY  apply a policy group with a specific SSH key

Replaces the former ansible/converge.yml. The only thing that does not
move here is first SPIRE enrollment (ansible/enroll.yml): it mints a one-time EAB with
the operator's Bao token, which no unattended run may hold. Nodes still unenrolled
are reported, not failed.

Bootstrap is part of the run: a node only needs SSH. A missing or wrong cinc-client
is installed from omnitruck (official sha256, fetched here so nodes need no internet).

"changed" means Cinc updated (or in why-run, would update) a resource, so a second
apply reporting changed=0 everywhere is the acceptance test, as in the rest of the repo.
"""

import argparse
import hashlib
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
INVENTORY = HERE / "ansible/inventory/hosts.yml"
# Shared with ansible/enroll.yml, so versions stay in one place.
GROUP_VARS = HERE / "ansible/inventory/group_vars/all.yml"
CACHE = Path.home() / ".cache/homelab-cinc"
RETRIES = 5  # the WAN drops at random

print_lock = threading.Lock()


def say(host, line):
    with print_lock:
        print(f"[{host.split('.')[0]}] {line}", flush=True)


def retry(what, fn):
    for attempt in range(RETRIES):
        try:
            return fn()
        except Exception as e:
            if attempt == RETRIES - 1:
                raise RuntimeError(f"{what}: {e}") from e
            time.sleep(10)


# ── pure helpers (covered by test_converge.py) ──────────────────────────────────

def load_nodes(inventory):
    hosts = inventory["all"]["children"]["cinc"]["hosts"]
    default_user = inventory["all"].get("vars", {}).get("ansible_user", "root")
    return [
        dict(host=h, policy=v["cinc_policy"], user=v.get("ansible_user", default_user),
             become=bool(v.get("ansible_become")))
        for h, v in hosts.items()
    ]


def select(nodes, limit):
    if not limit:
        return nodes
    want = set(limit.split(","))
    picked = [n for n in nodes if want & {n["host"], n["host"].split(".")[0], n["policy"]}]
    unknown = want - {k for n in nodes for k in (n["host"], n["host"].split(".")[0], n["policy"])}
    if unknown:
        raise SystemExit(f"--limit matches nothing: {', '.join(sorted(unknown))}")
    return picked


def updated_count(output):
    # "Infra Phase complete, N/M resources (would have been) updated". A failed run has
    # no such line; the caller fails it on the exit code, so 0 here hides nothing.
    m = re.search(r"Infra Phase complete, (\d+)/", output)
    return int(m.group(1)) if m else 0


def parse_omnitruck(text):
    meta = dict(line.split(None, 1) for line in text.splitlines() if line.strip())
    return meta["url"].strip(), meta["sha256"].strip()


# ── controller side ─────────────────────────────────────────────────────────────

def export_archives(policies, workstation, out):
    # With a lock present `cinc install` only fetches the pinned revisions into the
    # container's fresh cache, never re-resolving; `export` needs that cache.
    for p in policies:
        print(f"[export] {p}", flush=True)
        script = (f"cinc install {p}.rb >/dev/null && cinc export {p}.rb /out --archive >/dev/null"
                  f" && mv /out/{p}-*.tgz /out/{p}.tgz")
        retry(f"export {p}", lambda: subprocess.run(
            ["docker", "run", "--rm", "-u", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp",
             "-v", f"{HERE / 'policies'}:/p", "-v", f"{out}:/out", "-w", "/p",
             workstation, "bash", "-c", script],
            check=True, capture_output=True))


def cinc_package(platform, version):
    """Download (once, into CACHE) the cinc .deb for a platform; verified by omnitruck's sha256."""
    distro, release, arch = platform
    pv = release.split(".")[0] if distro == "debian" else release
    url = (f"https://omnitruck.cinc.sh/stable/cinc/metadata?p={distro}&pv={pv}&m={arch}&v={version}")
    deb_url, sha = parse_omnitruck(retry("omnitruck", lambda: urllib.request.urlopen(url, timeout=30).read().decode()))
    path = CACHE / Path(deb_url).name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == sha:
        return path
    CACHE.mkdir(parents=True, exist_ok=True)
    data = retry("download cinc", lambda: urllib.request.urlopen(deb_url, timeout=120).read())
    if hashlib.sha256(data).hexdigest() != sha:
        raise RuntimeError(f"sha256 mismatch for {deb_url}")
    path.write_bytes(data)
    return path


# ── node side ───────────────────────────────────────────────────────────────────

class Node:
    def __init__(self, n, identity):
        self.host, self.policy, self.user, self.become = n["host"], n["policy"], n["user"], n["become"]
        self.ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
        if identity:
            # ssh picks up <identity>-cert.pub on its own, so a Bao-signed cert just works.
            self.ssh += ["-i", identity, "-o", "IdentitiesOnly=yes"]
        self.ssh.append(f"{self.user}@{self.host}")

    def _wrap(self, cmd):
        # One hop only, so one round of quoting is enough. stdin carries any payload.
        return shlex.join(["sudo", "-n", "bash", "-c", cmd] if self.become else ["bash", "-c", cmd])

    def run(self, cmd, stdin=None, check=True):
        r = subprocess.run(self.ssh + [self._wrap(cmd)], stdin=stdin, capture_output=True, text=stdin is None)
        if check and r.returncode != 0:
            err = r.stderr if isinstance(r.stderr, str) else r.stderr.decode(errors="replace")
            raise RuntimeError(f"`{cmd.splitlines()[0]}` exited {r.returncode}: {err.strip()}")
        return r

    def stream(self, cmd):
        p = subprocess.Popen(self.ssh + [self._wrap(cmd)], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
        out = []
        for line in p.stdout:
            out.append(line)
            say(self.host, line.rstrip())
        return p.wait(), "".join(out)


def converge(n, cfg, archives, why_run, identity):
    node, d = Node(n, identity), cfg["cinc_node_dir"]
    staging = f"{d}/staging"

    installed = node.run("dpkg-query -W -f='${Version}' cinc", check=False).stdout
    if installed != f"{cfg['cinc_version']}-1":
        if why_run:
            # Nothing to why-run with: the client the policy needs is not there yet.
            say(node.host, f"would install cinc {cfg['cinc_version']} (have: {installed or 'none'})")
            return dict(result="would install cinc", changed=1)
        say(node.host, f"installing cinc {cfg['cinc_version']} (have: {installed or 'none'})")
        platform = tuple(node.run(". /etc/os-release && echo $ID $VERSION_ID $(uname -m)").stdout.split())
        deb = cinc_package(platform, cfg["cinc_version"])
        with open(deb, "rb") as f:
            node.run(f"cat > /var/cache/{deb.name} && "
                     f"DEBIAN_FRONTEND=noninteractive apt-get install -y -q /var/cache/{deb.name}", stdin=f)

    # Staging is scratch: rebuilt every run, never counted as a change.
    with open(archives / f"{node.policy}.tgz", "rb") as f:
        node.run(f"rm -rf {staging} && mkdir -p -m 0700 {staging} && tar -xzf - -C {staging}", stdin=f)

    # -c explicitly: Cinc finds .cinc/config.rb through $PWD; without it the run silently
    # "succeeds" with an empty run list.
    rc, out = node.stream(f"cd {staging} && /opt/cinc/bin/cinc-client -z --no-color "
                          f"-c {staging}/.cinc/config.rb" + (" --why-run" if why_run else ""))
    if rc != 0 or "has an empty run list" in out:
        node.run(f"rm -rf {staging}", check=False)
        return dict(result=f"FAILED (cinc exit {rc})", changed=0, failed=True)

    if why_run:
        node.run(f"rm -rf {staging}")
    else:
        # Only a successful apply is promoted: the drift timer must compare against what
        # was really applied. Then refresh the drift metric now rather than at the next
        # daily run, or drift fixed by this apply keeps alerting for up to a day.
        node.run(f"cd {d} && rm -rf previous && {{ [ ! -d policy ] || mv policy previous; }} && mv staging policy")
        node.run("systemctl start homelab-cinc-drift.service")

    result = "ok"
    if node.run("test -e /etc/spire-agent/node.crt", check=False).returncode != 0:
        result = "ok, SPIRE not enrolled (run ansible/enroll.yml)"
    return dict(result=result, changed=updated_count(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--why-run", action="store_true", help="preview only; changes nothing on any node")
    ap.add_argument("-l", "--limit", help="comma list of hosts (short or FQDN) and/or policy names")
    ap.add_argument("-i", "--identity", help="SSH private key (its -cert.pub is used if present)")
    args = ap.parse_args()

    cfg = yaml.safe_load(GROUP_VARS.read_text())
    nodes = select(load_nodes(yaml.safe_load(INVENTORY.read_text())), args.limit)

    with tempfile.TemporaryDirectory(prefix="cinc-") as tmp:
        export_archives(sorted({n["policy"] for n in nodes}), cfg["cinc_workstation"], tmp)

        def one(n):
            try:
                return n["host"], converge(n, cfg, Path(tmp), args.why_run, args.identity)
            except Exception as e:  # one node's failure must not hide the others' results
                say(n["host"], f"ERROR: {e}")
                return n["host"], dict(result=f"FAILED: {e}", changed=0, failed=True)

        with ThreadPoolExecutor(max_workers=len(nodes)) as pool:
            results = dict(pool.map(one, nodes))

    verb = "would change" if args.why_run else "changed"
    print(f"\n{'host':<32} {verb:>12}  result")
    for host, r in results.items():
        print(f"{host:<32} {r['changed']:>12}  {r['result']}")
    sys.exit(1 if any(r.get("failed") for r in results.values()) else 0)


if __name__ == "__main__":
    main()
