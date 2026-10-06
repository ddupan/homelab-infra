#!/usr/bin/env bash
# 依赖 Python 3 + PyYAML、promtool 3.5.0 和 vmalert-tool-prod 1.126.0。
# KSM 使用 MetricsQL 的 increase_prometheus，必须由真实 VM 引擎验证初值语义。
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$test_dir/../rules" "$check_dir/rules.yaml" <<'PY'
import pathlib
import sys
import yaml

groups = []
vm_groups = []
for name in ("kubernetes-health", "host-health", "monitoring-delivery", "platform-controllers", "data-services", "openbao", "shared-data-maintenance", "shared-postgresql-sql", "probes", "samba-dc", "ayatori", "proxmox", "vyos"):
    path = pathlib.Path(sys.argv[1]) / f"{name}.yaml"
    target = vm_groups if name == "kubernetes-health" else groups
    target.extend(yaml.safe_load(path.read_text())["spec"]["groups"])
pathlib.Path(sys.argv[2]).write_text(yaml.safe_dump({"groups": groups}, allow_unicode=True))
vm_names = {r["alert"] for g in vm_groups for r in g["rules"]}
output = pathlib.Path(sys.argv[2]).parent
(output / "vm-rules.yaml").write_text(yaml.safe_dump({"groups": vm_groups}, allow_unicode=True))
for path in pathlib.Path(sys.argv[1]).parent.joinpath("tests").glob("*.test.yaml"):
    # 0x20 是 promtool 样本序列，不能被 YAML 1.1 当成十六进制数。
    data = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    for engine in ("prom", "vm"):
        selected = []
        for test in data["tests"]:
            checks = [t for t in test.get("alert_rule_test", [])
                      if (t["alertname"] in vm_names) == (engine == "vm")]
            if checks:
                selected.append({**test, "alert_rule_test": checks})
        if selected:
            suite = {**data, "rule_files": ["vm-rules.yaml" if engine == "vm" else "rules.yaml"],
                     "tests": selected}
            (output / f"{engine}-{path.name}").write_text(yaml.safe_dump(suite, allow_unicode=True))
PY
promtool check rules "$check_dir/rules.yaml"
promtool test rules "$check_dir/"prom-*.test.yaml
vmalert-tool-prod unittest -disableAlertgroupLabel -files "$check_dir/vm-*.test.yaml"
