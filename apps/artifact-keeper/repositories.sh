#!/usr/bin/env bash
# 建 CI 下载缓存用的 remote 仓库（Go / PyPI / Galaxy / Docker Hub），已存在（409）即跳过。
# 用法：./repositories.sh；token（admin scope）默认取 OpenBao kv/infra/artifact-keeper 的 api_token，
# 也可用 AK_TOKEN 覆盖。Docker Hub 账号取同一路径的 dockerhub_username / dockerhub_token。
# 只建不改：仓库建好后改 upstream 等属性请在 UI 里做。
set -euo pipefail

base=${AK_URL:-https://artifacts.lab.ddupan.top}
token=${AK_TOKEN:-$(bao kv get -field=api_token kv/infra/artifact-keeper)}

api() {
  local method=$1 path=$2 body=$3
  curl -sS -w '\n%{http_code}' -X "$method" "$base/api/v1/$path" \
    -H "X-API-Key: $token" -H 'Content-Type: application/json' -d "$body"
}

create() {
  local key=$1 format=$2 upstream=$3 out code
  out=$(api POST repositories "{\"key\":\"$key\",\"name\":\"$key\",\"format\":\"$format\",\"repo_type\":\"remote\",\"visibility\":\"public\",\"upstream_url\":\"$upstream\"}")
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
create docker-hub docker https://registry-1.docker.io

# 匿名拉取按出口 IP 限流，全 lab 共用一个 IP；账号只需读公开镜像。每次都覆盖写，换 token 后重跑即可。
out=$(api PUT repositories/docker-hub/upstream-auth "$(jq -nc \
  --arg u "$(bao kv get -field=dockerhub_username kv/infra/artifact-keeper)" \
  --arg p "$(bao kv get -field=dockerhub_token kv/infra/artifact-keeper)" \
  '{auth_type:"basic",username:$u,password:$p}')")
code=${out##*$'\n'}
[[ $code == 2?? ]] || { echo "docker-hub upstream-auth: HTTP $code ${out%$'\n'*}" >&2; exit 1; }
echo "docker-hub: upstream auth set"
