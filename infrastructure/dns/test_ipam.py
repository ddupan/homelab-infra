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
BASE = generate.load_ipam()
AD = generate.ad_records()

def rejects(mutate, message):
    data, records = copy.deepcopy(BASE), copy.deepcopy(AD)
    mutate(data, records)
    try:
        generate.allocations(data, records)
    except ValueError as exc:
        assert message in str(exc), exc
    else:
        raise AssertionError(f"expected rejection: {message}")

def a_record(name, ip):
    return lambda d, records: records.append(
        {"zone": "ad.ddupan.top", "name": name, "type": "A", "values": [ip]})

generate.allocations(BASE, AD)
rejects(a_record("dup", "192.168.10.4"), "declare its host")           # 与 pve1 撞地址
rejects(a_record("pool", "192.168.10.200"), "non-static range")         # 落在 DHCP 池
rejects(a_record("stray", "172.16.0.5"), "outside every homelab_ipam")  # 不在任何网段
rejects(lambda d, _: d["homelab_ipam"]["addresses"].append(
    {"address": "192.168.10.1", "name": "again"}), "allocated twice")
rejects(lambda d, _: d["homelab_ipam"]["prefixes"].append(
    {"prefix": "10.0.0.0/25"}), "outside every lan/internal block")     # 落在外部前缀（OCI）
rejects(lambda d, _: d["homelab_ipam"]["prefixes"].append(
    {"prefix": "10.60.0.128/25"}), "overlaps")                         # 与 labnet 重叠
rejects(lambda d, _: d["homelab_ipam"]["blocks"].append(
    {"prefix": "172.20.0.0/16", "role": "host-local"}), "overlaps")    # docker 网络撞 dn42
rejects(lambda d, _: d["homelab_ipam"]["blocks"].append(
    {"prefix": "10.60.0.0/16", "role": "host-local"}), "overlaps")     # 只有 external 允许嵌套
rejects(lambda d, _: d["homelab_ipam"]["asns"].append({"asn": 65000}), "duplicate ASN")
# lab 区记录从 pdns 读入（live），与 AD 记录同样校验。
try:
    generate.allocations(BASE, AD + [{"name": "dup", "type": "A", "values": ["192.168.10.4"]}])
except ValueError as exc:
    assert "declare its host" in str(exc), exc
else:
    raise AssertionError("expected live record colliding with pve1 to be rejected")
# 同一主机同时出现在 ad. 与 lab.（迁移期）不是撞地址。
generate.allocations(BASE, AD + [{"name": "pve1", "type": "A", "values": ["192.168.10.4"]}])
assert str(generate.next_free(BASE, "10.61.0.0/24", AD)) == "10.61.0.2"
# 只在 zone 里注册、文件里没有的地址同样算占用（etcd-pve1 的教训）。
taken = [{"name": "x", "type": "A", "values": ["10.61.0.2"]}]
assert str(generate.next_free(BASE, "10.61.0.0/24", AD + taken)) == "10.61.0.3"
try:
    generate.next_free(BASE, "10.61.0.0/24",
                       [{"name": "pool", "type": "A", "values": ["192.168.10.200"]}])
except ValueError as exc:
    assert "non-static range" in str(exc), exc
else:
    raise AssertionError("expected live record in DHCP pool to be rejected")
try:
    generate.next_free(BASE, "10.62.1.0/24", AD)
except ValueError as exc:
    assert "allocated by ayatori-loadbalancer-dev" in str(exc), exc
else:
    raise AssertionError("expected VIP pool to refuse manual allocation")
print("ipam ok")
