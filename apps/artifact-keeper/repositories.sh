#!/usr/bin/env bash
# 建 CI 下载缓存用的 remote 仓库（Go / PyPI / Galaxy / Maven / Gradle 插件 / npm / Terraform / Docker Hub / GitHub release），已存在（409）即跳过。
# 用法：./repositories.sh；token（admin scope）默认取 OpenBao kv/infra/artifact-keeper 的 api_token，
# 也可用 AK_TOKEN 覆盖。Docker Hub 账号取同一路径的 dockerhub_username / dockerhub_token。
# 只建不改：仓库建好后改 upstream 等属性请在 UI 里做。缓存淘汰策略（文件末尾）每次按这里覆盖。
set -euo pipefail

base=${AK_URL:-https://artifacts.lab.ddupan.top}
token=${AK_TOKEN:-$(bao kv get -field=api_token kv/infra/artifact-keeper)}

api() {
  local method=$1 path=$2 data=()
  [[ -n ${3:-} ]] && data=(-d "$3")
  curl -sS -w '\n%{http_code}' -X "$method" "$base/api/v1/$path" \
    -H "X-API-Key: $token" -H 'Content-Type: application/json' "${data[@]}"
}

# api 的输出最后一行是状态码；非 2xx 时报错退出，否则打印响应体。
ok() {
  local what=$1 out=$2 code=${2##*$'\n'}
  [[ $code == 2?? ]] || { echo "$what: HTTP $code ${out%$'\n'*}" >&2; exit 1; }
  printf '%s\n' "${out%$'\n'*}"
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
create maven-central maven https://repo1.maven.org/maven2
# Gradle 插件解析（plugins {} 块）；插件 marker 在这里，实际 jar 多数重定向回 Maven Central。
create gradle-plugins maven https://plugins.gradle.org/m2
create npm-proxy npm https://registry.npmjs.org
# Provider Network Mirror（客户端经 TF_CLI_CONFIG_FILE 指向 /terraform/terraform-proxy/）。
create terraform-proxy terraform https://registry.terraform.io
create docker-hub docker https://registry-1.docker.io
# CI 下载 GitHub release（envtest、golangci-lint 等）；客户端用 /api/v1/repositories/github-releases/download/<owner>/<repo>/releases/download/<tag>/<asset>。
create github-releases generic https://github.com

# 匿名拉取按出口 IP 限流，全 lab 共用一个 IP；账号只需读公开镜像。每次都覆盖写，换 token 后重跑即可。
out=$(api PUT repositories/docker-hub/upstream-auth "$(jq -nc \
  --arg u "$(bao kv get -field=dockerhub_username kv/infra/artifact-keeper)" \
  --arg p "$(bao kv get -field=dockerhub_token kv/infra/artifact-keeper)" \
  '{auth_type:"basic",username:$u,password:$p}')")
ok "docker-hub upstream-auth" "$out" >/dev/null
echo "docker-hub: upstream auth set"

# 缓存淘汰：30 天没被下载的条目连对象带目录行删掉；上游没了的旧版本也会随之丢失，可接受。
# proxy cache 只认显式指派的 Remote 仓库（applies_to_all 的全局策略会跳过它），所以列出所有 key。
# 软删除后的物理清理由后端每小时的 storage GC 完成。
ids=$(for key in go-proxy pypi-proxy galaxy-proxy maven-central gradle-plugins npm-proxy terraform-proxy docker-hub github-releases; do
  ok "$key" "$(api GET "repositories/$key")" | jq -r .id
done | jq -Rsc 'split("\n") | map(select(. != ""))')
policy=$(jq -nc --argjson ids "$ids" '{
  name: "remote-cache-idle", description: "Remote 缓存 30 天未下载即淘汰（repositories.sh 管理）",
  policy_type: "no_downloads_days", config: {days: 30}, repository_ids: $ids,
  cron_schedule: "0 30 3 * * *", enabled: true}')
id=$(ok "lifecycle list" "$(api GET admin/lifecycle)" | jq -r '.[] | select(.name == "remote-cache-idle") | .id')
if [[ -z $id ]]; then
  ok "lifecycle create" "$(api POST admin/lifecycle "$policy")" >/dev/null
  echo "remote-cache-idle: created"
else
  ok "lifecycle update" "$(api PATCH "admin/lifecycle/$id" "$(jq -c 'del(.policy_type)' <<<"$policy")")" >/dev/null
  echo "remote-cache-idle: updated"
fi
