#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["Jinja2==3.1.6", "PyYAML==6.0.3"]
# ///
"""Render backend DNS configuration from records.yml."""

from __future__ import annotations

import argparse
import difflib
import ipaddress
import json
import os
from pathlib import Path
import sys
import urllib.request

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined


ROOT = Path(__file__).resolve().parents[2]
DNS_DIR = ROOT / "infrastructure/dns"
IPAM = ROOT / "infrastructure/network/ipam.yml"
# Read for IPAM only: samba-ad owns these records, this script just counts them.
AD_RECORDS = ROOT / "infrastructure/samba-ad/ansible/group_vars/all/dns.yml"
POWERDNS_ZONE_URL = "http://192.168.10.127:8053/api/v1/servers/localhost/zones/lab.ddupan.top."
BEGIN = "# BEGIN GENERATED: homelab DNS ([[ target ]])"
END = "# END GENERATED: homelab DNS ([[ target ]])"


def load_inventory() -> dict:
    data = yaml.safe_load((DNS_DIR / "records.yml").read_text())
    try:
        inventory = data["homelab_dns"]
        split_records = inventory["split_horizon"]["records"]
    except (KeyError, TypeError) as exc:
        raise ValueError(f"invalid DNS inventory: missing {exc}") from exc

    for record in split_records:
        require_fields(record, "name", "type", "values", "backends")
        if record["type"] != "A" or len(record["values"]) != 1:
            raise ValueError(f"split record must be a single A value: {record!r}")
        unknown = set(record["backends"]) - {"blocky", "coredns"}
        if unknown:
            raise ValueError(f"unknown split DNS backends {sorted(unknown)}")

    allocations(load_ipam(), ad_records())
    return inventory


def load_ipam() -> dict:
    return yaml.safe_load(IPAM.read_text())


def ad_records() -> list[dict]:
    return yaml.safe_load(AD_RECORDS.read_text())["samba_ad_dns_records"]


def allocations(data: dict, records: list[dict]) -> dict:
    """Validate homelab_ipam against A records and return {ip: owner}.

    Records live with their owners, not in records.yml, so callers pass them in:
    ad_records() always, plus the live lab.ddupan.top zone for --next-free.
    """
    ipam = data["homelab_ipam"]
    blocks = [(ipaddress.ip_network(b["prefix"]), b["role"]) for b in ipam["blocks"]]
    prefixes = [ipaddress.ip_network(p["prefix"]) for p in ipam["prefixes"]]
    # Only our own allocation inside external space (dn42) may nest.
    nested = {(inner, outer) for inner, inner_role in blocks for outer, role in blocks
              if inner_role == "dn42" and role == "external"
              and inner.version == outer.version and inner.subnet_of(outer)}
    for nets in ([net for net, _ in blocks], prefixes):
        for i, net in enumerate(nets):
            for other in nets[i + 1:]:
                if net.overlaps(other) and (net, other) not in nested and (other, net) not in nested:
                    raise ValueError(f"{net} overlaps {other}")
    for net in prefixes:
        if not any(net.subnet_of(block) for block, role in blocks if role in ("lan", "internal")):
            raise ValueError(f"prefix {net} is outside every lan/internal block")
    vlans = [p["vlan"] for p in ipam["prefixes"] if "vlan" in p]
    if len(vlans) != len(set(vlans)):
        raise ValueError(f"duplicate VLAN in {vlans}")
    asns = [a["asn"] for a in ipam["asns"]]
    if len(asns) != len(set(asns)):
        raise ValueError(f"duplicate ASN in {asns}")
    ranges = [(ipaddress.ip_address(r["start"]), ipaddress.ip_address(r["end"]), r["description"])
              for r in ipam["ranges"]]
    owners: dict = {}
    for entry in ipam["addresses"]:
        ip = ipaddress.ip_address(entry["address"])
        if ip in owners:
            raise ValueError(f"{ip} allocated twice: {owners[ip]} and {entry['name']}")
        owners[ip] = entry["name"]
    # An A record is itself an allocation. Several names on one address are only
    # legitimate when that address is declared as a shared host (ingress, router);
    # otherwise two records on one IP is the copy-paste mistake this exists to catch.
    # A host listed in both zones (ad. and lab., during the migration) is still one
    # host, so names are collected as a set.
    named: dict = {}
    for record in records:
        if record["type"] == "A":
            for value in record["values"]:
                names = named.setdefault(ipaddress.ip_address(value), [])
                if record["name"] not in names:
                    names.append(record["name"])
    for ip, names in named.items():
        if len(names) > 1 and ip not in owners:
            raise ValueError(f"{ip} is used by {', '.join(names)}; declare its host in homelab_ipam.addresses")
        owners.setdefault(ip, names[0])
    for ip, owner in owners.items():
        if not any(ip in net for net in prefixes):
            raise ValueError(f"{owner} ({ip}) is outside every homelab_ipam prefix")
        for start, end, description in ranges:
            if start <= ip <= end:
                raise ValueError(f"{owner} ({ip}) is inside a non-static range: {description}")
    return owners


def live_records() -> list[dict]:
    """A RRsets actually in lab.ddupan.top, in records.yml shape.

    Creators register their own names (lxc.yml, external-dns, Poweradmin), so the
    zone, not any file, is the complete set of used addresses. Without the key we
    fail rather than fall back to the file: a file-only answer is exactly how
    etcd-pve1/2 (10.60.0.20/21) went unseen and would have been handed out again.
    """
    key = os.environ.get("PDNS_API_KEY")
    if not key:
        raise ValueError("PDNS_API_KEY unset; run with "
                         "PDNS_API_KEY=$(bao kv get -field=api_key kv/k8s/powerdns)")
    request = urllib.request.Request(POWERDNS_ZONE_URL, headers={"X-API-Key": key})
    with urllib.request.urlopen(request, timeout=10) as response:
        zone = json.load(response)
    suffix = "." + zone["name"]
    return [{"name": rrset["name"].removesuffix(suffix), "type": "A",
             "values": [record["content"] for record in rrset["records"]]}
            for rrset in zone["rrsets"] if rrset["type"] == "A"]


def next_free(data: dict, prefix: str, records: list[dict]) -> ipaddress.IPv4Address:
    # Live records go through the same checks as declared ones, so a registered
    # address inside the DHCP pool or colliding with another host fails here too.
    owners = allocations(data, records)
    allocator = next((p.get("allocator") for p in data["homelab_ipam"]["prefixes"]
                      if ipaddress.ip_network(p["prefix"]) == ipaddress.ip_network(prefix)), None)
    if allocator:
        raise ValueError(f"{prefix} is allocated by {allocator}, not by hand")
    ranges = [(ipaddress.ip_address(r["start"]), ipaddress.ip_address(r["end"]))
              for r in data["homelab_ipam"]["ranges"]]
    for ip in ipaddress.ip_network(prefix).hosts():
        if ip not in owners and not any(start <= ip <= end for start, end in ranges):
            return ip
    raise ValueError(f"no free static address in {prefix}")


def require_fields(record: dict, *fields: str) -> None:
    missing = [field for field in fields if field not in record]
    if missing:
        raise ValueError(f"record missing {', '.join(missing)}: {record!r}")


def environment() -> Environment:
    return Environment(
        loader=FileSystemLoader(DNS_DIR / "templates"),
        undefined=StrictUndefined,
        autoescape=False,
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
        variable_start_string="[[",
        variable_end_string="]]",
        block_start_string="[%",
        block_end_string="%]",
    )


def marker(target: str, end: bool = False) -> str:
    return (END if end else BEGIN).replace("[[ target ]]", target)


def replace_block(original: str, target: str, rendered: str) -> str:
    begin = marker(target)
    end = marker(target, end=True)
    if original.count(begin) != 1 or original.count(end) != 1:
        raise ValueError(f"expected exactly one generated block for {target}")
    prefix, remainder = original.split(begin, 1)
    _, suffix = remainder.split(end, 1)
    indent = prefix.rsplit("\n", 1)[-1]
    body = rendered.rstrip("\n")
    return f"{prefix}{begin}\n{body}\n{indent}{end}{suffix}"


def outputs(inventory: dict) -> dict[Path, str]:
    env = environment()
    split_records = inventory["split_horizon"]["records"]
    result = {}

    blocky_path = ROOT / "apps/blocky/config.yml"
    blocky = env.get_template("blocky.yml.j2").render(
        records=[record for record in split_records if "blocky" in record["backends"]]
    )
    result[blocky_path] = replace_block(blocky_path.read_text(), "blocky", blocky)

    coredns_path = ROOT / "platform/k3s/coredns-custom.yaml"
    coredns = env.get_template("coredns.yaml.j2").render(
        records=[record for record in split_records if "coredns" in record["backends"]]
    )
    result[coredns_path] = replace_block(coredns_path.read_text(), "coredns", coredns)

    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when generated files differ")
    parser.add_argument("--next-free", metavar="PREFIX", help="print the first unallocated static address")
    args = parser.parse_args()
    if args.next_free:
        try:
            print(next_free(load_ipam(), args.next_free, ad_records() + live_records()))
        except (OSError, ValueError, KeyError) as exc:
            print(f"ipam lookup failed: {exc}", file=sys.stderr)
            return 2
        return 0
    try:
        rendered_outputs = outputs(load_inventory())
    except (OSError, KeyError, ValueError, yaml.YAMLError) as exc:
        print(f"dns generation failed: {exc}", file=sys.stderr)
        return 2

    changed = False
    for path, expected in rendered_outputs.items():
        actual = path.read_text() if path.exists() else ""
        if actual == expected:
            continue
        changed = True
        if args.check:
            print("".join(difflib.unified_diff(
                actual.splitlines(keepends=True),
                expected.splitlines(keepends=True),
                fromfile=str(path.relative_to(ROOT)),
                tofile=f"{path.relative_to(ROOT)} (generated)",
            )))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
            print(f"rendered {path.relative_to(ROOT)}")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
