#!/usr/bin/env python3
"""Generate the VyOS interface + OSPF config from NetBox.

    uv run --with requests python netbox/generate/vyos-ospf.py [--diff]

This is the ONE case CONTEXT.md §8 step 5 nominates as worth automating: today the VyOS
interface addresses, the `area 0 network` list and the PVE SDN VNets must be kept in sync
BY HAND, and forgetting the OSPF line is silent — the subnet exists, has a gateway, and
is simply unreachable from anywhere else.

DERIVATION RULES (these are the interesting part, not the code):

  addresses   every IP assigned to a vyos-rtr interface
  area 0      every prefix that vyos-rtr HAS AN INTERFACE IN
  passive     interfaces whose prefix has role `sdn`

The second rule matters. The obvious rule — "the SDN prefixes" — is WRONG and was caught
by diffing against the live router: it omits 192.168.10.0/24, but the LAN must be in
area 0 or VyOS has no adjacency with the NEC IX or the laptop and nothing is advertised
at all. Deriving from "where does this router actually have an address" produces the LAN
for free and cannot forget a future VNet.

The third rule is why eth0 is NOT passive: it is the only interface that must form
adjacencies. eth1/eth2 face guests and are advertised without peering.

Read-only. It prints config; it does not touch the router.
"""
from __future__ import annotations

import ipaddress
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

ROUTER = "vyos-rtr"

envfile = Path(__file__).parent.parent / "terraform" / ".env"
if envfile.exists():
    for line in envfile.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k, v)

BASE = os.environ.get("NETBOX_URL", "").rstrip("/") + "/api"
TOKEN = os.environ.get("NETBOX_TOKEN", "")
if not TOKEN:
    sys.exit("NETBOX_TOKEN not set (expected in netbox/terraform/.env)")


def get(path: str):
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def generate() -> list[str]:
    vm = get(f"/virtualization/virtual-machines/?name={ROUTER}")["results"]
    if not vm:
        sys.exit(f"{ROUTER} not found in NetBox")

    prefixes = get("/ipam/prefixes/?limit=200")["results"]
    ifaces = sorted(get(f"/virtualization/interfaces/?virtual_machine_id={vm[0]['id']}")["results"],
                    key=lambda i: i["name"])

    lines, areas, passive = [], [], []
    for iface in ifaces:
        for addr in get(f"/ipam/ip-addresses/?vminterface_id={iface['id']}")["results"]:
            lines.append(f"set interfaces ethernet {iface['name']} address '{addr['address']}'")

            ip = ipaddress.ip_interface(addr["address"]).ip
            # The prefix this address sits in == a network this router participates in.
            for p in prefixes:
                if ip in ipaddress.ip_network(p["prefix"]):
                    if p["prefix"] not in areas:
                        areas.append(p["prefix"])
                    if (p.get("role") or {}).get("slug") == "sdn":
                        passive.append(iface["name"])
                    break

    # Keep the LAN first: it is the transit network, and reading the config that way
    # matches how the adjacency is reasoned about.
    areas.sort(key=lambda p: (not p.startswith("192.168."), p))
    lines += [f"set protocols ospf area 0 network '{p}'" for p in areas]
    lines += [f"set protocols ospf interface {i} passive" for i in sorted(set(passive))]
    return lines


def live() -> list[str]:
    out = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "vyos@192.168.10.2",
         "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands"],
        capture_output=True, text=True, timeout=60).stdout
    return [l.strip() for l in out.splitlines()
            if ("ospf area" in l or "ospf interface" in l or
                ("ethernet eth" in l and "address" in l))]


if __name__ == "__main__":
    gen = generate()
    if "--diff" not in sys.argv:
        print("\n".join(gen))
        sys.exit(0)

    have = live()
    only_live = [l for l in have if l not in gen]
    only_gen = [l for l in gen if l not in have]
    for l in gen:
        print(("  " if l in have else "+ ") + l)
    for l in only_live:
        print("- " + l)
    print(f"\nmatched={len(gen) - len(only_gen)} generated_only={len(only_gen)} live_only={len(only_live)}")
    sys.exit(1 if (only_gen or only_live) else 0)
