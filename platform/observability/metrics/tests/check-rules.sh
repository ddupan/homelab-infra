#!/usr/bin/env bash
# 依赖 Python 3 + PyYAML，以及 PATH 中的 promtool（验证版本 3.5.0）。
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$test_dir/../rules" "$check_dir/rules.yaml" <<'PY'
import pathlib
import sys
import yaml

groups = []
for name in ("kubernetes-health", "host-health", "monitoring-delivery", "platform-controllers", "data-services", "openbao", "shared-data-maintenance", "shared-postgresql-sql", "probes", "samba-dc", "ayatori", "proxmox"):
    path = pathlib.Path(sys.argv[1]) / f"{name}.yaml"
    groups.extend(yaml.safe_load(path.read_text())["spec"]["groups"])
pathlib.Path(sys.argv[2]).write_text(yaml.safe_dump({"groups": groups}, allow_unicode=True))
PY
cp "$test_dir/"*.test.yaml "$check_dir/"
promtool check rules "$check_dir/rules.yaml"
promtool test rules "$check_dir/"*.test.yaml
