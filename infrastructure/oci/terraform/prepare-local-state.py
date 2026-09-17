#!/usr/bin/env python3
"""从已下载的 state 初始化本地恢复环境，不输出 metadata，也不覆盖现有文件。"""
import json
import os
from pathlib import Path
import sys

os.umask(0o077)
source = Path(sys.argv[1])
raw = source.read_bytes()
state = json.loads(raw)
vm = next(r for r in state['resources'] if r['mode'] == 'managed'
          and r['type'] == 'oci_core_instance' and r['name'] == 'vm')
root = Path(__file__).resolve().parent
local = root / '.recovery' / 'terraform.tfstate'
variables = root / 'terraform.tfvars.json'
if local.exists() or variables.exists():
    sys.exit('本地 state 或 tfvars 已存在；请先核对并自行备份，脚本不会覆盖。')
local.parent.mkdir(mode=0o700, exist_ok=True)
with local.open('xb') as f:
    f.write(raw)
with variables.open('x') as f:
    json.dump({'instance_metadata': vm['instances'][0]['attributes']['metadata']}, f, indent=2)
    f.write('\n')
print('已准备本地 state 和 metadata 变量；未修改远端。')
