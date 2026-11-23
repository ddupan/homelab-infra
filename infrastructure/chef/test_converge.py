"""python3 -m pytest infrastructure/chef/test_converge.py (or run directly)."""
import re
from pathlib import Path

import pytest
from packaging.version import Version

from converge import changed_resources, load_nodes, parse_omnitruck, scope_from_changes, select, updated_count

INV = {"all": {"vars": {"ansible_user": "root"}, "children": {"cinc": {"hosts": {
    "etcd-pve1.lab.ddupan.top": {"cinc_policy": "base"},
    "lb-prod-1.lab.ddupan.top": {"cinc_policy": "loadbalancer-prod"},
    "ayatori-dev.lab.ddupan.top": {"cinc_policy": "ayatori-dev", "ansible_user": "panxiao81", "ansible_become": True},
}}}}}


def test_load_nodes():
    nodes = {n["host"]: n for n in load_nodes(INV)}
    assert nodes["etcd-pve1.lab.ddupan.top"]["user"] == "root"
    assert nodes["ayatori-dev.lab.ddupan.top"]["user"] == "panxiao81"
    assert nodes["ayatori-dev.lab.ddupan.top"]["become"] is True


def test_select():
    nodes = load_nodes(INV)
    assert len(select(nodes, None)) == 3
    assert [n["host"] for n in select(nodes, "etcd-pve1")] == ["etcd-pve1.lab.ddupan.top"]
    assert [n["host"] for n in select(nodes, "loadbalancer-prod")] == ["lb-prod-1.lab.ddupan.top"]
    with pytest.raises(SystemExit):
        select(nodes, "etcd-pve9")  # a typo must never silently select nothing


def test_updated_count():
    assert updated_count("Infra Phase complete, 3/40 resources updated in 5 seconds") == 3
    assert updated_count("Infra Phase complete, 0/40 resources would have been updated") == 0
    assert updated_count("ERROR: something broke") == 0


def test_parse_omnitruck():
    text = "sha1\tabc\nsha256\tdeadbeef\nurl\thttps://x/cinc_19.3.14-1_amd64.deb\nversion\t19.3.14\n"
    assert parse_omnitruck(text) == ("https://x/cinc_19.3.14-1_amd64.deb", "deadbeef")


def test_scope_from_changes():
    c = "infrastructure/chef/"
    assert scope_from_changes([c + "policies/base.lock.json", c + "policies/loadbalancer-prod.rb"]) == {
        "base", "loadbalancer-prod"}
    assert scope_from_changes([c + "README.md", c + "ansible/enroll.yml", c + "test_converge.py"]) == set()
    assert scope_from_changes([c + "policies/base.rb", c + "converge.py"]) is None
    assert scope_from_changes([c + "ansible/inventory/hosts.yml"]) is None
    assert scope_from_changes([".github/workflows/chef.yml"]) is None


def test_changed_resources():
    out = ("  - homelab_base (0.4.3)\n"
           "  * apt_update[daily] action periodic\n"
           "    * execute[apt-get -q update] action run\n"
           "      - execute [\"apt-get\", \"-q\", \"update\"]\n"
           "    - update new lists of packages\n"
           "[2026-11-03T15:10:19+00:00] ERROR: shard_seed - noise\n")
    assert changed_resources(out) == ['- execute ["apt-get", "-q", "update"]', "- update new lists of packages"]


# Ayatori 版本偏差（ayatori ADR-0024）：LB agent 不新于 manager 的 release，最多落后一个 minor。
# 放在这个文件里而不是新文件：改 chef.yml 的测试命令会让合并时 apply 全部节点。
def within_skew(manager, agent):
    return agent <= manager and agent.major == manager.major and agent.minor >= manager.minor - 1


def pinned(policy, attr):
    text = (Path(__file__).parent / "policies" / f"{policy}.rb").read_text()
    return Version(re.search(rf"^default{re.escape(attr)} = '([^']+)'", text, re.M).group(1))


def test_within_skew():
    assert within_skew(Version("v0.3.1"), Version("0.3.0"))
    assert within_skew(Version("v0.4.0"), Version("0.3.9"))
    assert within_skew(Version("v0.3.0"), Version("0.3.0-rc.3"))
    assert not within_skew(Version("v0.3.0"), Version("0.3.1"))  # agent 新于 manager
    assert not within_skew(Version("v0.3.0-rc.3"), Version("0.3.0"))
    assert not within_skew(Version("v0.5.0"), Version("0.3.9"))  # 落后两个 minor
    assert not within_skew(Version("v1.0.0"), Version("0.9.0"))  # 跨 major


@pytest.mark.parametrize("env", ["dev", "prod"])
def test_ayatori_agent_within_skew(env):
    manager = pinned(f"ayatori-{env}", "['homelab_ayatori']['release']")
    agent = pinned(f"loadbalancer-{env}", "['homelab_loadbalancer']['agent']['version']")
    assert within_skew(manager, agent), f"{env}: manager {manager} 与 LB agent {agent} 超出版本偏差，见 ayatori ADR-0024"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
