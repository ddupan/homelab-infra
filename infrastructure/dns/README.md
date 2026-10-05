# DNS 声明与权威边界

`records.yml` 是 homelab DNS 的唯一声明清单，但不是 DNS 服务本身。不同视图仍由最适合
它们的后端提供：

| 视图 | 权威或递归服务 | 配置方式 |
|---|---|---|
| 公网 `ddupan.top` | Cloudflare | 由生成器输出 Terraform；尚待完整导入已有记录 |
| 内部 `lab.ddupan.top` | PowerDNS（`apps/blocky/`，经 Blocky 条件转发） | 生成器输出 `terraform/dns.generated.tf`，CI apply；HTTPRoute 名由 external-dns 写，临时记录用 Poweradmin |
| AD `ad.ddupan.top` | Samba internal DNS（迁移完成后只剩 AD 自身记录） | `samba_dns_record` Ansible module |
| LAN split horizon | Blocky | 由生成器维护 `customDNS.mapping` 标记块 |
| Kubernetes Pod split horizon | CoreDNS | 由生成器维护 `.server` 标记块 |

## 生成配置

安装了 `uv` 后，在仓库根目录运行：

```bash
uv run infrastructure/dns/generate.py
uv run infrastructure/dns/generate.py --check
```

脚本使用内嵌锁定版本的 PyYAML 和 Jinja2，从 `records.yml` 渲染四个目标：

- `apps/blocky/config.yml` 中带 marker 的 LAN split-horizon mapping；
- `platform/k3s/coredns-custom.yaml` 中带 marker 的 Pod split-horizon server blocks；
- `infrastructure/cloudflared/terraform/dns.generated.tf` 中已经完成 Terraform 接管的公网记录。
- `infrastructure/dns/terraform/dns.generated.tf` 中 `lab.ddupan.top` 的固定主机（`homelab_dns.powerdns`）。
  zone、SOA、NS 在同目录手写的 `main.tf`。CI 的 `tf.py` 从 bao `kv/k8s/powerdns` 取 API key。

生成文件需要提交进 Git，以便 PR 直接审阅最终配置。CI 执行 `--check`，任何手工修改生成块、
漏跑生成器或非确定性输出都会失败。Jinja 使用 `[[ ... ]]` 作为变量定界符，避免与 CoreDNS
模板表达式 `{{ .Name }}` 冲突。

`backends` 和 `terraform.managed` 是分阶段接管开关，而不是第二份记录数据：只有已经完成
零变更接管的后端才会生成。把记录加入新的后端前，应先完成相应的 live/state 对账。

## 地址分配（IPAM）

`records.yml` 同时是地址分配表，取代 NetBox。A 记录本身就是一次分配；
`homelab_ipam` 只补它表达不了的部分：网段、DHCP 池与预留段（`ranges`），以及没有静态
A 记录的地址（`addresses`：路由器、网关、自行向 AD 注册 DNS 的域成员、AP、laptop）。

`generate.py` 每次运行都会校验：地址必须落在某个网段内、不得落在 `ranges` 内、
`addresses` 不得重复；同一 IP 被多条 A 记录引用时（ingress、路由器），必须在
`addresses` 中声明它属于哪台主机，否则视为误用。`test_ipam.py` 覆盖这些拒绝路径。

分配新静态地址：

```bash
uv run infrastructure/dns/generate.py --next-free 192.168.10.0/24
```

它只知道登记过的地址。2026-10-04 对 `.1–.127` 做过 ping/ARP 扫描，在线地址与清单
完全一致；之后接入未登记的设备会让它给出错误答案，所以静态地址先登记再使用。

## 安全边界

- Samba module 只管理 `homelab_dns.samba.records` 明确列出的 RRset，不遍历或清理 zone。
- `_ldap`、`_kerberos`、域控制器 locator 等由 Samba 自动维护的记录不进入 inventory。
- 一个受管 RRset 默认使用 `exact: true`：同名同类型的额外值会被删除，但其他名称和类型
  不受影响。
- DHCP 切换不属于本阶段。Blocky 仍未成为 LAN 客户端的正式 resolver。

## 分阶段接管

1. 用 Samba module 接管现有静态 A RRset，首次 check mode 应为零变更。
2. 将 Cloudflare 已有 tunnel DNS 记录逐条导入 Terraform state，再启用 `terraform.managed`。
3. Blocky 与 CoreDNS 已从 `split_horizon.records` 生成；通过 `backends` 分阶段扩展。
4. 验证公网、LAN、Pod、AD 四个视图后，再单独修改 DHCP。

当前 inventory 明确保留一个既有差异：`obj.ddupan.top` 的 `backends` 只有 Blocky，CoreDNS
尚无对应覆盖。本阶段不改变线上语义；后续验证 Pod 侧入口后再加入 `coredns`。

CoreDNS split-horizon 的原因是避免集群内请求经 Cloudflare 公网绕回同一个集群。尤其 Gitea
启动时会访问 Authelia discovery URL，公网路径故障曾令其启动失败；生成块仍返回相同 LAN A
记录，并对 AAAA 返回 NOERROR/no-data。

## 服务名迁移：`*.ad.ddupan.top` → `*.lab.ddupan.top`

Samba 最终只保留 AD 自身记录。迁移期间新旧名并存：HTTPRoute 同时挂 `https` 与 `https-lab`
两个监听器（一个监听器只有一个 hostname），lab 记录由 external-dns 自动发布；旧名的 Samba
A 记录等所有客户端切走后再删。

| 批次 | 服务 | 状态 / 还差什么 |
|---|---|---|
| 1 | dns、nexus、s3、metrics-write | 双名。已切：9 个 TF backend、seaweedfs provider、nexus TF `nexus_url`（本地已有 `.terraform` 的需 `terraform init -reconfigure`）、zot `regionendpoint`。待切：sandbox vmagent remoteWrite（sandbox 走 DC 解析，须先把 DC forwarder 指向 Blocky） |
| 2 | grafana、backstage | `root_url` / `BACKSTAGE_BASE_URL` 与 OIDC 回调绑定单一名字，需与 IdP 客户端注册一起切 |
| 3 | zot、zot-push | 约 10 处镜像引用 + Flux ImageRepository + push 端 bearer realm，最后单独切 |
| 4 | spire-oidc、bao、nats、pg-dev 等 | issuer / 证书 SAN / 非 HTTP，逐个设计 |

Tailnet 客户端靠 MagicDNS split DNS `lab.ddupan.top -> 192.168.10.127`（admin console 手工配置）。
