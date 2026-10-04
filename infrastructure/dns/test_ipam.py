#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["Jinja2==3.1.6", "PyYAML==6.0.3"]
# ///
"""Self-check for generate.py's IPAM validation: each mistake it exists to catch."""

import copy
import importlib.util
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("generate", HERE / "generate.py")
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)
BASE = yaml.safe_load((HERE / "records.yml").read_text())


def rejects(mutate, message):
    data = copy.deepcopy(BASE)
    mutate(data)
    try:
        generate.allocations(data)
    except ValueError as exc:
        assert message in str(exc), exc
    else:
        raise AssertionError(f"expected rejection: {message}")


def a_record(name, ip):
    return lambda d: d["homelab_dns"]["samba"]["records"].append(
        {"zone": "ad.ddupan.top", "name": name, "type": "A", "values": [ip]})


generate.allocations(BASE)
rejects(a_record("dup", "192.168.10.4"), "declare its host")           # 与 pve1 撞地址
rejects(a_record("pool", "192.168.10.200"), "non-static range")         # 落在 DHCP 池
rejects(a_record("stray", "172.16.0.5"), "outside every homelab_ipam")  # 不在任何网段
rejects(lambda d: d["homelab_ipam"]["addresses"].append(
    {"address": "192.168.10.1", "name": "again"}), "allocated twice")
assert str(generate.next_free(BASE, "10.61.0.0/24")) == "10.61.0.2"
print("ipam ok")
