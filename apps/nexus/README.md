# Nexus Repository POC

本目录声明一个 Nexus Repository Community Edition POC，用来验证一次性 CI runner 通过
网络服务复用 Ansible Galaxy、Go Modules 与 OCI/BuildKit 缓存。Nexus 固定为 `3.96.1`，
镜像固定到官方 multi-arch index digest；LAN 入口为
`https://nexus.ad.ddupan.top`。

## POC 边界

- 单副本 Deployment，`Recreate` 更新，避免一个 RWO 卷被两个 Pod 同时挂载。
- `/nexus-data` 使用 `localpv-zfs-ceph` 上的 50 GiB RWO PVC。
- 资源预算为 250m/2 GiB request、2 CPU/4 GiB limit；JVM heap 上限 2 GiB。
- 使用容器默认的 embedded H2。它只用于 POC；正式接管 OCI 制品前必须迁移到外部
  PostgreSQL，并验证备份恢复。
- 入口只在 LAN wildcard Gateway 上发布，不创建公网 DNS 或 Cloudflare route。
- 不套 Authelia forward-auth；它会破坏 Go、Ansible 与 OCI 非浏览器客户端。
- 现有 zot 保持不变。Nexus 完成 OCI、BuildKit cache 和恢复验收前不得迁移或删除 zot。

POC 先由 Terraform 创建 `ansible-public` 和 `go-public`。Nexus 3.94 才加入的原生 OCI
repository 已有 REST API，但当前锁定的 community provider 尚未暴露 OCI resource；不能
因此在 UI 中创建一个无人管理的长期 repository。POC 上线后先根据实例 Swagger 固定
请求 schema，再补 Terraform provider resource 或受测试的声明式 REST 适配。

## 部署

Flux 从 `clusters/homelab/apps/nexus.yaml` 协调本目录，并依赖 Envoy Gateway 与 OpenEBS。
合并前只渲染配置，不直接 apply：

```bash
kubectl kustomize apps/nexus
```

合并并由 Flux 部署后检查：

```bash
kubectl -n flux-system get kustomization nexus
kubectl -n nexus get pod,pvc,service,httproute
kubectl -n nexus logs deployment/nexus --tail=100
```

启动可能需要数分钟，startup probe 允许最多十分钟。不要因初次启动较慢反复删除 Pod；
先确认 PVC 已 Bound、Pod 没有 OOM，以及日志仍在推进。

DNS 期望状态已加入 `infrastructure/dns/records.yml`，需从 Samba AD Ansible root 以
`--check --diff` 核对后再按其 README 应用 DNS tag。没有 DNS 时可先用 port-forward
验证应用，但不能据此宣称 Gateway 路径已通过。

## 首次初始化与 Terraform

初始管理员密码生成在 PVC 的 `/nexus-data/admin.password`。只在交互式终端中读取并立即
完成首次密码轮换；不得把密码复制进 shell tracing、工单、Git 或命令参数。随后将
Terraform 管理账号的凭据存入 OpenBao，由 CI 注入以下环境变量：

```text
NXRM_SERVER_URL=https://nexus.ad.ddupan.top
NXRM_SERVER_USERNAME=<OpenBao 注入>
NXRM_SERVER_PASSWORD=<OpenBao 注入>
```

`terraform/` 使用 `sonatype-nexus-community/sonatyperepo` 1.17.0，当前声明：

- `ansible-galaxy-proxy` → `https://galaxy.ansible.com`
- `ansible-public` group
- `go-proxy` → `https://proxy.golang.org`
- `go-public` group

provider credential 不写入 HCL 或 tfvars。正式 apply 前还必须为这个独立 Terraform root
配置远端 backend；本地 state 只允许用于可丢弃的 POC，不提交。验证命令：

```bash
terraform -chdir=apps/nexus/terraform init -backend=false
terraform -chdir=apps/nexus/terraform validate
```

## 客户端验收

先验证冷缓存，再原样重复命令验证热缓存；记录 Nexus 请求、上游流量和耗时，不只观察
命令成功。Ansible 配置的 URL 必须以 `/` 结尾：

```ini
[galaxy]
server_list = nexus

[galaxy_server.nexus]
url = https://nexus.ad.ddupan.top/repository/ansible-public/
```

```bash
ansible-galaxy collection install -r collections/requirements.yml \
  -p .ansible/collections
```

Go POC 使用：

```bash
GOPROXY=https://nexus.ad.ddupan.top/repository/go-public/ go mod download
```

私有 `git.ddupan.top/*` module 的 `GOPRIVATE`、凭据与是否允许 `direct` fallback 在实际
workflow 中单独决定；不要让私有 module path 意外发往公共 proxy。

OCI 阶段至少验证普通 push/pull、multi-arch、OCI 1.1 referrers、Cosign、Helm OCI，
以及 BuildKit `registry` cache 的 `mode=max` 导入导出。Nexus 上游已有 BuildKit cache
兼容性问题记录，因此该项失败时不能用普通镜像 push 成功代替。全部通过并完成备份恢复
演练后，才评估 zot 迁移。

## 数据与恢复

POC 的数据库、配置、blob、初始管理员状态都位于 `nexus-data` PVC。删除 Deployment
不会删除 PVC；删除 PVC 会永久删除整个 POC。当前没有独立备份，不能将它用于唯一副本的
正式制品。

恢复验证至少包括：停止写入、取得一致备份、在独立 PVC/实例恢复、登录、列出 repository、
拉取已缓存的 Ansible/Go 制品，并核对 OCI digest/referrers。正式化时再把数据库迁移至
外部 PostgreSQL，并分别定义数据库与 blob 的备份、恢复顺序和 RPO。

参考：

- [Nexus OCI repositories](https://help.sonatype.com/en/oci-repositories.html)
- [Nexus Ansible repositories](https://help.sonatype.com/en/ansible-repositories.html)
- [Nexus Go repositories](https://help.sonatype.com/en/go-repositories.html)
- [官方容器镜像](https://hub.docker.com/r/sonatype/nexus3)
