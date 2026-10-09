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
POWERDNS_ZONE_URL = "http://192.168.10.127:8053/api/v1/servers/localhost/zones/lab.ddupan.top."
BEGIN = "# BEGIN GENERATED: homelab DNS ([[ target ]])"
END = "# END GENERATED: homelab DNS ([[ target ]])"


def load_inventory() -> dict:
    data = yaml.safe_load((DNS_DIR / "records.yml").read_text())
    try:
        inventory = data["homelab_dns"]
        split_records = inventory["split_horizon"]["records"]
        public_records = inventory["public"]["records"]
    except (KeyError, TypeError) as exc:
        raise ValueError(f"invalid DNS inventory: missing {exc}") from exc

    for record in split_records:
        require_fields(record, "name", "type", "values", "backends")
        if record["type"] != "A" or len(record["values"]) != 1:
            raise ValueError(f"split record must be a single A value: {record!r}")
        unknown = set(record["backends"]) - {"blocky", "coredns"}
        if unknown:
            raise ValueError(f"unknown split DNS backends {sorted(unknown)}")

    for record in public_records:
        require_fields(record, "name", "type", "values", "proxied", "terraform")
        terraform = record["terraform"]
        if terraform.get("managed") and not terraform.get("resource_name"):
            raise ValueError(f"managed Terraform record needs resource_name: {record['name']}")
        if len(record["values"]) != 1:
            raise ValueError(f"Cloudflare Terraform supports one value per record: {record['name']}")
    check_retired(inventory["samba"])
    allocations(data)
    return inventory


def check_retired(samba: dict) -> None:
    """A retired RRset is deleted by the role; also managing it would flap every run."""
    for record in samba.get("retired", []):
        require_fields(record, "zone", "name", "type")
    key = lambda r: (r["zone"], r["name"], r["type"])
    both = {key(r) for r in samba.get("retired", [])} & {key(r) for r in samba["records"]}
    if both:
        raise ValueError(f"samba RRsets both managed and retired: {sorted(both)}")


def allocations(data: dict, live: list[dict] = ()) -> dict:
    """Validate homelab_ipam against the A records and return {ip: owner}.

    lab.ddupan.top records live with their owners, not in this file, so they only
    count when passed in as `live` (read from pdns by --next-free).
    """
    ipam = data["homelab_ipam"]
    prefixes = [ipaddress.ip_network(p["prefix"]) for p in ipam["prefixes"]]
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
    records = data["homelab_dns"]["samba"]["records"] + list(live)
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


def next_free(data: dict, prefix: str, live: list[dict]) -> ipaddress.IPv4Address:
    # Live records go through the same checks as declared ones, so a registered
    # address inside the DHCP pool or colliding with another host fails here too.
    owners = allocations(data, live)
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
    public_records = inventory["public"]["records"]
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

    terraform_path = ROOT / "infrastructure/cloudflared/terraform/dns.generated.tf"
    terraform = env.get_template("cloudflare.tf.j2").render(
        records=[record for record in public_records if record["terraform"]["managed"]]
    )
    result[terraform_path] = terraform
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when generated files differ")
    parser.add_argument("--next-free", metavar="PREFIX", help="print the first unallocated static address")
    args = parser.parse_args()
    if args.next_free:
        try:
            data = yaml.safe_load((DNS_DIR / "records.yml").read_text())
            print(next_free(data, args.next_free, live_records()))
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
