# OCI 云上基础设施

`terraform/` 是独立 Terraform 根模块，从 OCI Object Storage 中的现有 state 恢复。
Terraform 管理云 API 资源；实例内的软件、Kubernetes 和操作系统配置不在该 state 中。

## 资源与来源

- Region：`ap-osaka-1`，compartment 为 tenancy 根。
- State：namespace `axckv9ylwqxr`，bucket `oci-k8s-free-tier-tfstate`，key `terraform.tfstate`。
- 恢复源：2026-08-15 12:26:24 UTC 对象，25,261 字节，serial `249`，
  lineage `c945c6c4-ee01-d7b7-23f5-37207ea60609`，Terraform `1.15.8`。
- 7 个受管资源保留原地址：`oci_core_instance.vm`、`oci_core_vcn.vcn`、
  `oci_core_subnet.public`、`oci_core_internet_gateway.igw`、`oci_core_route_table.public`、
  `oci_core_security_list.public`、`oci_limits_quota.free_tier_quota`。
- 2 个数据源：`oci_core_images.ubuntu`、`oci_identity_availability_domains.ads`；保留 4 个原输出。
- VM：`homelab-vm`，A1 Flex，2 OCPU / 12 GB RAM / 100 GB 启动盘，
  私网 `10.0.0.124`，恢复时公网 `129.225.138.179`。
- VCN `10.0.0.0/16`，公共子网 `10.0.0.0/24`，默认路由经 Internet Gateway；
  入站保留 TCP 22、UDP 41641、ICMP type 3/code 4，出站全部允许。
- 配额语句为 A1 4 核 / 24 GB（暂时放宽，用于验证 PAYG 是否仍按旧额度免费，见 `a1-payg-probe.tf`）、10 个卷、200 GB 总存储限制；这些语句不是费用保证。
- Bucket 自身不在 state 内，不由此根模块管理。
- 费用告警不用 OCI Budget：`platform/observability/metrics/exporters/cloud-cost.yaml` 经 `finops.tf` 的
  只读用户读 Usage API，告警走 Alertmanager。账户已升级 PAYG，Always Free 之外的用量直接计费。
  采集器有自己的 OAuth client，apply 后把 `cost_exchange_client_id`、`cost_exchange_client_secret` 两个
  output 写进 Bao `kv/k8s/cloud-cost`（`oci_client_id`、`oci_client_secret`）。

## 恢复设计

原变量、模块意图、provider 精确版本和生命周期规则无法从 state 完整恢复。
本次选择并锁定 `oracle/oci 9.1.0`，提交 lockfile；这不是声称找回了原 provider 版本。
资源间的 VCN、路由表、安全列表、子网和 DHCP 引用已重建。
启动镜像固定为现有 image OCID，避免数据源选中更新镜像导致 VM 替换。
新增 `prevent_destroy` 保护现有 VM；没有用 `ignore_changes` 掩盖配置差异。

Provider 使用本机 `~/.oci/config` 的 `DEFAULT` profile，可用变量覆盖 profile 和 region。
metadata 经敏感变量传入，只保存在忽略的 `terraform.tfvars.json`，不进入版本库。
State、plan、metadata 变量与 `.terraform/` 都不得提交；plan JSON 同样可能含敏感数据。
保留原目录的恢复要求：保留 lineage/serial，先复现当前 VM 和公共网络设计，
实际基础设施变更前达到严格零变更，并保护实例及启动盘；迁移私有子网须单独评审。
已用既有 GPG 加密子密钥 `5A6A04D1B216C64E` 创建独立加密源备份
`.recovery/source.tfstate.gpg`；本地原始副本的 lineage/serial 保持不变。

## 日常维护

旧 Terraform/CI 已由维护者确认停用，当前仓库已接管原 OCI Object Storage state。
`versions.tf` 使用 OCI backend，直接连接原对象，未迁移本地恢复副本。

已接入 CI（`TF_ROOTS`），合并即 apply。CI 没有 API key：`.github/scripts/tf.py` 用 SPIRE JWT-SVID
（`aud=oci`）换 1 小时的 UPST，以 `terraform-ci` 服务用户运行（`terraform/spire-federation.tf`）。
依赖 Bao 的 `kv/infra/oci-token-exchange`（`client_id`、`client_secret`）和
`kv/infra/terraform/oci`（`instance_metadata`，JSON 字符串）。

- OCI 对 aud 或 subject 不匹配返回 500，不是 4xx。换 token 报 500 时先查这两项，不要重试。
- 更换 trust 引用的服务用户要分两步：先 `-target` 更新 trust，再删旧用户。OCI 不允许删除被
  trust 引用的用户，Terraform 也不知道这层依赖。
- 新建的 Customer Secret Key 要约 10 分钟才完全生效，期间请求时好时坏。IAM 策略约 1.5 分钟生效。

本地手动运行时认证沿用本机 OCI CLI 的 `DEFAULT` profile；不要在配置中写密钥。

```bash
cd infrastructure/oci/terraform
terraform init
terraform validate
terraform plan -input=false -out=change.tfplan
# 核对计划后执行：
terraform apply change.tfplan
```

新 checkout 需从受限 state 副本提取 metadata 至被忽略的 `terraform.tfvars.json`。
`prepare-local-state.py` 可执行这一步，同时保留 `.recovery/terraform.tfstate` 备份；
当前 backend 使用远端对象，`.recovery/` 中的副本不再参与日常 plan/apply。
下载前设置 `umask 077`，并使用 GPG 加密源备份；不要把本地副本上传覆盖远端。

## GitHub 镜像

Gitea 仓库通过服务端推送镜像同步到 GitHub 组织 `ddupan` 的私有仓库，作为 Gitea 不可用时的异地副本。
镜像会强推远端，所以 GitHub 上的改动会被覆盖；不要在那边提交。

新增仓库后，或更换 token 时运行（需要 `gh`、`tea` 和可读 Bao 的会话）：

```bash
python3 infrastructure/oci/github-mirror.py           # 补齐缺失的仓库和镜像
python3 infrastructure/oci/github-mirror.py --rotate  # 用 Bao 里的新 token 重建镜像
```

- token 是 fine-grained PAT，只限 `ddupan` 组织，存于 Bao `kv/infra/gitea-github-mirror` 的
  `GITHUB_TOKEN`。最长 366 天，到期前换新并运行 `--rotate`，否则镜像会静默停止更新。
- 必须在 GitHub 上关闭 Actions，否则镜像过去的 workflow 可能运行；脚本在首次推送前逐仓库关闭。
  例外见脚本里的 `ACTIONS_ALLOWED`：这些仓库用 GitHub Actions 向 ghcr 发布镜像，脚本不会改动它们的 Actions 开关。
- Gitea 拒绝给归档仓库加推送镜像，脚本会跳过并打印出来。
- 不要从本地 checkout 推送到 GitHub：本地 ref 可能带有从未发布到 Gitea 的历史。

## 恢复验证记录

Terraform 1.15.8、OCI provider 9.1.0 验证通过。
恢复计划唯一更新是 VM metadata 的敏感标记，plan JSON 中 before/after 值相同。
经授权 apply 后，本地完整刷新 plan 达到 `No changes`。
旧 state 在 provider 刷新后补充 VM shape/VNIC、subnet IPv4 CIDR、route type 字段，
这些读回差异没有产生基础设施修改计划。
接管时重新连接原远端对象，因此新增实例计划也包含原 VM 的同一敏感标记归一化。

## AMD 实例

`oci_core_instance.amd` 配置为 `homelab-amd`，`VM.Standard.E2.1.Micro`，1 GB RAM，
Ubuntu 24.04 x86_64，50 GB / 10 VPU 启动盘。复用现有公共子网和 SSH 公钥，
没有复制 A1 实例的其他初始化内容，也不部署 Kubernetes。
镜像固定为 `Canonical-Ubuntu-24.04-2026.08.25-0`，实例具有 `prevent_destroy` 保护。

创建前 API 确认大阪为 home region、机型计费类型为 `ALWAYS_FREE`，AMD 配额剩余 2 台。
存储盘点只有 A1 的 100 GB 启动盘；已核对两个启动盘合计 150 GB，200 GB 免费额度内剩余 50 GB。
免费额度跨启动盘和块存储共享；后续新增资源仍需重新核对实际占用。

实例已创建并确认 `RUNNING`，私网 `10.0.0.158`，公网 `129.225.176.134`。
登录命令：`ssh ubuntu@129.225.176.134`（本次未验证 SSH 登录）。
远端 state 已保存；创建后完整刷新 plan 为 `No changes`，退出码 0。

参考：[Always Free 资源](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)、
[OCI provider 认证](https://docs.oracle.com/en-us/iaas/Content/dev/terraform/configuring.htm)、
[OCI backend 配置](https://developer.hashicorp.com/terraform/language/backend/oci)。

## DNS 登录入口

- ARM：`ssh ubuntu@oci-arm.ddupan.top`
- AMD：`ssh ubuntu@oci-amd.ddupan.top`

公网 A 记录在 Cloudflare 上关闭代理，TTL 300 秒，连同 Gitea 的 `git.ddupan.top`（开代理）由
`terraform/dns.tf` 管理，内容直接取实例的公网 IP，删除重建实例时随 apply 更新。
Cloudflare token 与 zone ID 由 tf.py 从 Bao `kv/infra/terraform/cloudflared` 注入，与 cloudflared root 共用。

## WireGuard/BGP 与 DN42

家中端点已从 laptop 迁移到 VyOS `192.168.10.2`，AMD 与 VyOS 同属 AS4242421811，
通过独立 WireGuard 接口建立双栈 iBGP；laptop 只与 NEC IX 跑 BGP，经 IX 学到的路由由 VyOS 转发。
Ansible 配置与运行方法见 [ansible/README.md](ansible/README.md)。

注册前缀 `172.21.111.160/27`、`fdd0:98df:15b0::/48` 已在内部路由中准备：
VyOS `.161` / `::1`，AMD `.162` / `::2`，使用 loopback /32、/128。
首个外部 DN42 peer 已接入 RoutedBits Osaka（AS4242420207），AMD 使用独立 `wg-dn42-1`
和单 IPv6 MP-BGP 会话承载双栈；详见 [Ansible runbook](ansible/README.md)。
外部明细留在 AMD，`172.20.0.0/14`、`fd00::/8` 汇总经 iBGP 下发 VyOS；IPv4 /14 再由 VyOS 经 eBGP 通告给 NEC IX（2026-10-16 起替代 OSPF），LAN 经 IX 到达 VyOS。
LAN 的 DN42 IPv6 /64 地址由 VyOS SLAAC 下发，fd00::/8 通过 RA RIO 分发，不通告 IPv6 默认路由。内部家中/OCI 业务路由不得向外部 DN42 邻居通告。

Terraform 管理 AMD NSG、VNIC 转发与 VCN 回程；Ansible 管理路由器/主机及 ARM 的 Tailscale
回程例外。Docker 与 DN42 的 /14 地址重叠已迁出，见 [Docker runbook](../docker/README.md)。

VyOS 的 `wg42` 主 IPv4 已改为注册的 `172.21.111.161/32`，内部 BGP 改为
单 link-local IPv6 会话承载双栈。三个 LAN 私网到 DN42 /14 由 VyOS 定向 masquerade，
排除本 AS /27；OCI 业务保持原源地址。IPv6 不做 NAT，三个 LAN 的 SLAAC 与专用路由通告由 `infrastructure/proxmox/ansible` 的 `vyos_router` 管理。
