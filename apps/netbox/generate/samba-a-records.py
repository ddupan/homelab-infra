#!/usr/bin/env python3
"""Generate samba_ad_extra_a_records from NetBox.

    uv run --with requests --with pyyaml python netbox/generate/samba-a-records.py [--diff]

CONTEXT.md §4 item 3: the AD DNS A records for non-domain-joined hosts are hand-listed in
../../../infrastructure/samba-ad/ansible/group_vars/all/vars.yml, duplicating addresses that already live in
NetBox. This derives them instead.

SOURCE OF TRUTH FOR *WHICH* HOSTS: the `dns_name` field on the NetBox IP address. That is
intent, not a derived fact — domain-joined machines register themselves in AD DNS and must
NOT get a static record, so "every IP in the LAN prefix" would be wrong. An address gets a
record iff someone set dns_name on it.

Deliberately NOT handled: service/ingress names such as netbox.ad.ddupan.top, which point
at the k3s gateway rather than at a host. Several of those share one address, and NetBox's
dns_name is single-valued per IP, so they stay hand-managed in vars.yml. This tool only
owns HOST records.

Read-only: prints YAML and diffs. It never writes to the DC — ../../../infrastructure/samba-ad applies it
(`ansible-playbook provision-dc.yml --tags dns`).
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

ZONE = "ad.ddupan.top"
VARS = Path(__file__).parents[3] / "infrastructure/samba-ad/ansible/group_vars/all/vars.yml"

envfile = Path(__file__).parent.parent / "terraform" / ".env"
if envfile.exists():
    for line in envfile.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

BASE = os.environ.get("NETBOX_URL", "https://netbox.ad.ddupan.top").rstrip("/") + "/api"
TOKEN = os.environ.get("NETBOX_TOKEN", "")
if not TOKEN:
    sys.exit("NETBOX_TOKEN not set (expected in netbox/terraform/.env)")


def get(path: str):
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def generate() -> list[dict]:
    out = []
    for a in get("/ipam/ip-addresses/?limit=500")["results"]:
        dns = (a.get("dns_name") or "").strip().lower()
        if not dns.endswith(f".{ZONE}"):
            continue
        name = dns[: -len(f".{ZONE}")]
        ip = str(ipaddress.ip_interface(a["address"]).ip)
        out.append({"name": name, "ip": ip})
    # Stable order so the diff is meaningful rather than churn.
    return sorted(out, key=lambda r: ipaddress.ip_address(r["ip"]))


def current() -> list[dict]:
    """Parse the existing hand-written list without pulling in the whole vars file."""
    if not VARS.exists():
        return []
    txt = VARS.read_text()
    m = re.search(r"^samba_ad_extra_a_records:\s*$(.*?)(?=^\S)", txt, re.S | re.M)
    if not m:
        return []
    return [{"name": n, "ip": i}
            for n, i in re.findall(r'name:\s*"([^"]+)".*?ip:\s*"([^"]+)"', m.group(1))]


if __name__ == "__main__":
    gen = generate()
    if "--diff" not in sys.argv:
        print("samba_ad_extra_a_records:")
        for r in gen:
            print(f'  - {{ name: "{r["name"]}", ip: "{r["ip"]}" }}')
        sys.exit(0)

    have = {(r["name"], r["ip"]) for r in current()}
    want = {(r["name"], r["ip"]) for r in gen}
    for n, i in sorted(want | have, key=lambda x: ipaddress.ip_address(x[1])):
        mark = "  " if (n, i) in want and (n, i) in have else ("+ " if (n, i) in want else "- ")
        print(f"{mark}{n:<10} {i}")
    print(f"\nin both={len(want & have)}  netbox only={len(want - have)}  vars.yml only={len(have - want)}")
    print("\n+ = NetBox has it, vars.yml does not   - = hand-listed, not derivable from NetBox")
