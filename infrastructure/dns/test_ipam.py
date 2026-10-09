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
# 同一 RRset 不能既受管又退役：两个任务会来回删建。
samba = copy.deepcopy(BASE["homelab_dns"]["samba"])
samba["retired"].append({"zone": "ad.ddupan.top", "name": "pve1", "type": "A"})
try:
    generate.check_retired(samba)
except ValueError as exc:
    assert "both managed and retired" in str(exc), exc
else:
    raise AssertionError("expected managed+retired rejection")
generate.check_retired(BASE["homelab_dns"]["samba"])
# lab 区记录从 pdns 读入（live），与 AD 记录同样校验。
try:
    generate.allocations(BASE, [{"name": "dup", "type": "A", "values": ["192.168.10.4"]}])
except ValueError as exc:
    assert "declare its host" in str(exc), exc
else:
    raise AssertionError("expected live record colliding with pve1 to be rejected")
# 同一主机同时出现在 ad. 与 lab.（迁移期）不是撞地址。
generate.allocations(BASE, [{"name": "pve1", "type": "A", "values": ["192.168.10.4"]}])
assert str(generate.next_free(BASE, "10.61.0.0/24", [])) == "10.61.0.2"
# 只在 zone 里注册、文件里没有的地址同样算占用（etcd-pve1 的教训）。
taken = [{"name": "x", "type": "A", "values": ["10.61.0.2"]}]
assert str(generate.next_free(BASE, "10.61.0.0/24", taken)) == "10.61.0.3"
try:
    generate.next_free(BASE, "10.61.0.0/24",
                       [{"name": "pool", "type": "A", "values": ["192.168.10.200"]}])
except ValueError as exc:
    assert "non-static range" in str(exc), exc
else:
    raise AssertionError("expected live record in DHCP pool to be rejected")
print("ipam ok")
