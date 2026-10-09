# DNS 声明与权威边界

`lab.ddupan.top` 的记录跟着它的 owner 走：谁创建资源，谁在自己的 root 里注册名字。
其余视图仍由 `records.yml` 统一声明、生成到各后端（这是 AD DNS 时代的折中，正在逐个拆掉）：

| 视图 | 权威或递归服务 | 配置方式 |
|---|---|---|
| 公网 `ddupan.top` | Cloudflare | 由生成器输出 Terraform；尚待完整导入已有记录 |
| 内部 `lab.ddupan.top` | PowerDNS（`apps/blocky/`，经 Blocky 条件转发） | zone 与没有母资源的主机在 `terraform/hosts.tf`（手动注册）；有 owner 的记录在 owner 的 root（incus：ayatori-*，etcd `lxc.yml`：etcd-pve*）；HTTPRoute 名由 external-dns 写，临时记录用 Poweradmin |
| AD `ad.ddupan.top` | Samba internal DNS（迁移完成后只剩 AD 自身记录） | `samba_dns_record` Ansible module |
| LAN split horizon | Blocky | 由生成器维护 `customDNS.mapping` 标记块 |
| Kubernetes Pod split horizon | CoreDNS | 由生成器维护 `.server` 标记块 |

## 生成配置

安装了 `uv` 后，在仓库根目录运行：

```bash
uv run infrastructure/dns/generate.py
uv run infrastructure/dns/generate.py --check
```

脚本使用内嵌锁定版本的 PyYAML 和 Jinja2，从 `records.yml` 渲染三个目标：

- `apps/blocky/config.yml` 中带 marker 的 LAN split-horizon mapping；
- `platform/k3s/coredns-custom.yaml` 中带 marker 的 Pod split-horizon server blocks；
- `infrastructure/cloudflared/terraform/dns.generated.tf` 中已经完成 Terraform 接管的公网记录。

`lab.ddupan.top` 不经生成器。CI 的 `tf.py` 给 dns 与 incus root 从 bao `kv/k8s/powerdns` 取 API key；
新增一个注册 lab 记录的 root 时把它加进那个判断。

生成文件需要提交进 Git，以便 PR 直接审阅最终配置。CI 执行 `--check`，任何手工修改生成块、
漏跑生成器或非确定性输出都会失败。Jinja 使用 `[[ ... ]]` 作为变量定界符，避免与 CoreDNS
模板表达式 `{{ .Name }}` 冲突。

`backends` 和 `terraform.managed` 是分阶段接管开关，而不是第二份记录数据：只有已经完成
零变更接管的后端才会生成。把记录加入新的后端前，应先完成相应的 live/state 对账。

## 地址分配（IPAM）

IPAM 只维护**地址池**；"哪个地址被谁占用"以 DNS 为准。

- `homelab_ipam`（本文件）：网段、DHCP 池与预留段（`ranges`，单个租约不归 IPAM 管），
  以及没有 A 记录的地址（`addresses`：路由器、网关、自行向 AD 注册的域成员、AP、laptop）。
- 已占用集合 = 上述 `addresses` + 本文件里 AD 区的 A 记录 + **`lab.ddupan.top` 里实际存在的
  A 记录**。资源由创建者自己注册 DNS（incus Terraform、`etcd/ansible/lxc.yml`、external-dns、
  Poweradmin），不回写本文件；`--next-free` 运行时从 PowerDNS API 读取 zone。

校验对两类记录相同：地址必须落在某个网段内、不得落在 `ranges` 内、`addresses` 不得重复；
同一 IP 被多个名字引用时（ingress、路由器），必须在 `addresses` 声明归属。`test_ipam.py`
覆盖这些拒绝路径。`--check`（CI）只校验文件，不访问 PowerDNS，因此不检查 lab 区。

分配新静态地址：

```bash
PDNS_API_KEY=$(bao kv get -field=api_key kv/k8s/powerdns) \
  uv run infrastructure/dns/generate.py --next-free 10.60.0.0/24
```

没有 key 时直接失败，不退回只读文件——只看文件正是 etcd-pve1/2（10.60.0.20/21）部署后对
IPAM 不可见的原因。分配之后立即注册 DNS：两步之间没有预留，单人操作下可接受。

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
| 1 | dns、nexus、s3、metrics-write | 双名。已切：9 个 TF backend、seaweedfs provider、nexus TF `nexus_url`（本地已有 `.terraform` 的需 `terraform init -reconfigure`）、zot `regionendpoint`、sandbox vmagent remoteWrite（sandbox 节点用 DC 解析，DC forwarder 已是 Blocky）。批次 1 客户端全部切完 |
| 2 | grafana、backstage | `root_url` / `BACKSTAGE_BASE_URL` 与 OIDC 回调绑定单一名字，需与 IdP 客户端注册一起切 |
| 3 | zot、zot-push | 约 10 处镜像引用 + Flux ImageRepository + push 端 bearer realm，最后单独切 |
| 4 | spire-oidc、bao、nats、pg-dev 等 | issuer / 证书 SAN / 非 HTTP，逐个设计 |

Tailnet 客户端靠 MagicDNS split DNS `lab.ddupan.top -> 192.168.10.127`（admin console 手工配置）。
