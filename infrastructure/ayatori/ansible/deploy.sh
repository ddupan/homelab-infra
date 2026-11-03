#!/usr/bin/env bash
# 用法：./deploy.sh prod [ansible-playbook 参数...]
# 每个环境安装自己的 Ayatori release，只对该环境的主机执行。
set -euo pipefail
env=${1:?用法：./deploy.sh prod}
shift
case "$env" in prod) ;; *) echo "未知环境：$env" >&2; exit 2 ;; esac
cd "$(dirname "$0")"
ansible-galaxy collection install --force -r "requirements-$env.yml" -p ".collections/$env"
ANSIBLE_COLLECTIONS_PATH=".collections/$env" exec ansible-playbook site.yml --limit "$env" "$@"
