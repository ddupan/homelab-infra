# 网络规划

LAN 是一台傻瓜交换机下的扁平二层（192.168.10.0/24），上面有三个路由 speaker。本文定下
它们各自的职责、地址怎么划、AS 怎么分，新网段、新 VIP、新 BGP 邻居都按这里来。
地址与 AS 的数据在 [`ipam.yml`](ipam.yml)，由 `infrastructure/dns/generate.py` 校验。

**范围只有 IPv4。** 节点都没有 IPv6 接入，本规划也没有为 IPv6 设计路由；`ipam.yml` 里的
IPv6 前缀只是占位登记（dn42 的 v6 只在 VyOS 的 wg42 上）。要接入 IPv6 时单独规划。

## 路由职责

| 设备 | 职责 | 不做什么 |
|---|---|---|
| NEC IX（192.168.10.1，AS65000） | 出口、LAN 默认网关与 DHCP；OSPF `originate-default` | 不承载内部服务路由，不直接和业务主机建 BGP |
| VyOS（VM 100，192.168.10.2） | 内部路由核心：SDN VNet 网关、VIP（LB 主机经 BGP 宣告）、dn42/OCI overlay；把这些注入 OSPF | 不再新增 HAProxy 服务或手工 VIP |
| laptop FRR（192.168.10.127，AS65001） | OSPF speaker；向 IX 宣告 NAIST 前缀（既有特例） | 不扩展成新的路由角色 |

约束与取舍：

- **IX 的路由预算是个位数。** 它性能有限，只收汇总前缀：内部地址、外部 overlay、NAIST；
  不收单个服务的 /32，VIP 增删不应改变它的路由表。目标是内部地址只剩 `10.60.0.0/14` 一条
  （见迁移清单）。
- **LAN 主机访问内部地址多绕一跳，接受。** 普通 LAN 主机的网关是 IX，去程 IX → VyOS，
  回程 VyOS 直接回 LAN。不为此把 LAN 设备的网关改成 VyOS。
- **因此 IX 与 VyOS 都不得对 LAN↔内部地址的流量做状态过滤。** 上述来回路径不对称，
  stateful 过滤只看到单向，会丢包。2026-10-15 核对：IX 的 LAN 口没有 `ip filter`/SPI，VyOS
  未配置 firewall。将来 retronet 的防火墙策略只限定在 retronet 出口方向。
- **VyOS 是内部地址的单点。** 它只有 PVE HA 重启（约 1–3 分钟）；内部服务越多越关键，
  第二台 VyOS + VRRP 是已知风险，计划处理。

## 不做 overlay

VXLAN/EVPN 这类 overlay 在这里太重：多一套控制面（EVPN 的 BGP）和 VTEP，排障面翻倍，而它
能解决的问题这里要么没有、要么有更轻的解法：

- 让 PVE 之外的主机接入内部网段：交换机透传 802.1Q，VLAN 就够（见下文"主机地址"）。
- 服务地址不绑定在某个二层上：用 L3 解决，VIP 由 LB 主机经 BGP 宣告。
- 租户隔离、跨站点二层迁移：没有这个需求。

VLAN ID 记在 `ipam.yml` 对应网段的 `vlan` 字段，校验不得重复；4094 个对 homelab 足够。
出现 VLAN 和路由都解决不了的需求再重新评估。

## 地址

`ipam.yml` 的 `blocks` 是顶层占位，彼此不得重叠：

- `lan`：192.168.10.0/24，IX 网关的扁平二层。
- `internal`：10.60.0.0/14，VyOS 后面的一切。已用 10.60.0.0/24 labnet、10.61.0.0/24
  retronet、10.62.0.0/24 Prod VIP、10.62.1.0/24 Dev VIP；新 VNet 或 VIP 池从剩余空间取。
- `external`：经路由引入、不归我们分配的前缀（OCI、ISP 侧、Tailscale、NAIST、dn42）。
- `dn42`：本站在 dn42 的分配（172.21.111.160/27、fdd0:98df:15b0::/48），唯一允许嵌在
  external block 里的占位。
- `host-local`：只在某台主机内部存在的网段（k3s Pod/Service、docker、libvirt）。列出来是为了
  新网段不撞上它们——它们一旦和路由前缀重叠，那台主机就会把流量送进本地网桥。

`prefixes` 是可以分配静态地址的网段，必须落在 `lan` 或 `internal` block 内；带 `allocator`
的网段由该系统自行分配，`--next-free` 拒绝。VIP 段是 LoadBalancer 专用的：只有 LB
controller 从中分配（IPAddress 对象），其他用途不与它共用。

### 主机地址跟着接入的二层走

没有真正的 vnet，主机只能用它所接网段的地址，不能任意分配：

| 主机在哪 | 能接的网段 | 网关 |
|---|---|---|
| PVE 集群 | SDN VNet（labnet、retronet） | VyOS |
| PVE 集群 | LAN（vmbr0 不打 tag） | IX |
| PVE 之外（laptop 的 Incus/libvirt 等） | 只有 LAN（br0） | IX |

VIP 不受此限：它是经 BGP 宣告的路由，不在任何二层上，所以可以从 internal 剩余空间划段。
将来 Ayatori 给主机分地址，地址池也只能是某个网段内的一段（`ranges`），不是独立前缀。

放置规则：**PVE 上的基础设施主机放 labnet**（etcd、LB 已是如此）；PVE 之外的主机只能放 LAN。
另一条可选路：傻瓜交换机透传 802.1Q tag（2026-07-25 实测），laptop 可以在 br0 上加 VLAN 100
直接接入 labnet，但目前没有这样做，也不在本规划内。

## AS

`ipam.yml` 的 `asns` 是登记表，不得重复。私有 AS 按用途分段：65000–65099 既有路由器，
65100–65199 Ayatori LoadBalancer（每个环境一个 AS，同环境主机共用，VyOS 按邻居过滤前缀）。
VyOS 的 BGP 实例使用 dn42 的 4242421811，内部邻居都是 eBGP。

## IPAM

IPAM 只维护**地址池**；"哪个地址被谁占用"以 DNS 为准。

- `ipam.yml`：网段、DHCP 池与预留段（`ranges`，单个租约不归 IPAM 管），以及没有 A 记录的
  地址（`addresses`：路由器、网关、自行向 AD 注册的域成员、AP、laptop）。
- 已占用集合 = 上述 `addresses` + samba-ad `group_vars/all/dns.yml` 的 AD 记录 +
  **`lab.ddupan.top` 里实际存在的 A 记录**。资源由创建者自己注册 DNS（incus Terraform、
  `etcd/ansible/lxc.yml`、external-dns、Poweradmin），不回写本文件；`--next-free` 运行时从
  PowerDNS API 读取 zone。

校验：block 之间、prefix 之间都不得重叠；prefix 必须在 lan/internal block 内；AS 不得重复；
地址必须落在某个 prefix 内、不得落在 `ranges` 内、`addresses` 不得重复；同一 IP 被多个名字
引用时（ingress、路由器），必须在 `addresses` 声明归属。`infrastructure/dns/test_ipam.py`
覆盖这些拒绝路径。`--check`（CI）只校验文件，不访问 PowerDNS，因此不检查 lab 区。

分配新静态地址：

```bash
PDNS_API_KEY=$(bao kv get -field=api_key kv/k8s/powerdns) \
  uv run infrastructure/dns/generate.py --next-free 10.60.0.0/24
```

没有 key 时直接失败，不退回只读文件——只看文件正是 etcd-pve1/2（10.60.0.20/21）部署后对
IPAM 不可见的原因。分配之后立即注册 DNS：两步之间没有预留，单人操作下可接受。

## 与规划不符的现状（迁移清单，未执行）

1. **IX 收到内部明细。** labnet、retronet 以 intra-area 网络进 area 0，另有 VyOS 上的
   10.60.0.13/32（sandbox K3s API）。收敛成一条 `10.60.0.0/14` 需要 VyOS 成为 ABR
   （SDN 接口进非骨干 area，`area range` 汇总）；VIP 用 BGP `aggregate-address` 后再注入。
2. **VyOS 上的 HAProxy 服务**：sandbox-postgresql（10.60.0.1:5432）、sandbox-k3s-api 与
   opensandbox-api（10.60.0.13）。LoadBalancer 上线后迁走，删除 10.60.0.13/32。
3. **pg-prod 解析到 VyOS（192.168.10.2）。** 随上一条一起改为 VIP。
4. **IX 的 laptop 邻居未过滤。** 补按邻居的入方向 prefix 过滤（只收 NAIST 两条）。
5. **docker 自动分配会撞 dn42。** docker 默认地址池含 172.17–172.31，laptop 已自动用到
   172.18/172.19，下一个自动网络就是 172.20.0.0/16，与 dn42 路由重叠。在 laptop 的
   `daemon.json` 设 `default-address-pools`，指向一个登记过的 host-local block。
6. ~~ayatori-dev/prod LXC 在 LAN~~：它们在 laptop 的 Incus 上，只能接 LAN，符合规划，不迁移。
