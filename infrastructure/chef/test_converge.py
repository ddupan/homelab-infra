"""python3 -m pytest infrastructure/chef/test_converge.py (or run directly)."""
import pytest

from converge import load_nodes, parse_omnitruck, select, updated_count

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


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
