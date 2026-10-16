#!/usr/bin/env bash
# 建 CI 下载缓存用的 remote 仓库（Go / PyPI / Galaxy），已存在（409）即跳过。
# 用法：AK_TOKEN=<admin scope 的 API token> ./repositories.sh
# 只建不改：仓库建好后改 upstream 等属性请在 UI 里做。
set -euo pipefail

base=${AK_URL:-https://artifacts.lab.ddupan.top}
: "${AK_TOKEN:?需要 admin scope 的 API token}"

create() {
  local key=$1 format=$2 upstream=$3 out code
  out=$(curl -sS -w '\n%{http_code}' -X POST "$base/api/v1/repositories" \
    -H "X-API-Key: $AK_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"key\":\"$key\",\"name\":\"$key\",\"format\":\"$format\",\"repo_type\":\"remote\",\"visibility\":\"public\",\"upstream_url\":\"$upstream\"}")
  code=${out##*$'\n'}
  case $code in
    2??) echo "$key: created" ;;
    409) echo "$key: exists" ;;
    *) echo "$key: HTTP $code ${out%$'\n'*}" >&2; return 1 ;;
  esac
}

create go-proxy go https://proxy.golang.org
create pypi-proxy pypi https://pypi.org/simple
create galaxy-proxy ansible https://galaxy.ansible.com
