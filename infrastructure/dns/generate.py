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
from pathlib import Path
import sys

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined


ROOT = Path(__file__).resolve().parents[2]
DNS_DIR = ROOT / "infrastructure/dns"
BEGIN = "# BEGIN GENERATED: homelab DNS ([[ target ]])"
END = "# END GENERATED: homelab DNS ([[ target ]])"


def load_inventory() -> dict:
    data = yaml.safe_load((DNS_DIR / "records.yml").read_text())
    try:
        inventory = data["homelab_dns"]
        split_records = inventory["split_horizon"]["records"]
        public_records = inventory["public"]["records"]
        powerdns_records = inventory["powerdns"]["records"]
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

    seen = set()
    for record in powerdns_records:
        require_fields(record, "name", "type", "values")
        # Relative to lab.ddupan.top; the template appends the zone.
        if "." in record["name"]:
            raise ValueError(f"powerdns record name must be relative to lab.ddupan.top: {record['name']}")
        key = (record["name"], record["type"])
        if key in seen:
            raise ValueError(f"duplicate powerdns RRset {key}; list every value in one entry")
        seen.add(key)
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


def allocations(data: dict) -> dict:
    """Validate homelab_ipam against the A records and return {ip: owner}."""
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
    records = data["homelab_dns"]["samba"]["records"] + data["homelab_dns"]["powerdns"]["records"]
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


def next_free(data: dict, prefix: str) -> ipaddress.IPv4Address:
    owners = allocations(data)
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

    powerdns_path = ROOT / "infrastructure/dns/terraform/dns.generated.tf"
    result[powerdns_path] = env.get_template("powerdns.tf.j2").render(
        records=inventory["powerdns"]["records"]
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when generated files differ")
    parser.add_argument("--next-free", metavar="PREFIX", help="print the first unallocated static address")
    args = parser.parse_args()
    if args.next_free:
        try:
            print(next_free(yaml.safe_load((DNS_DIR / "records.yml").read_text()), args.next_free))
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
