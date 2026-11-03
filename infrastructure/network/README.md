# 网络规划

LAN 是一台傻瓜交换机下的扁平二层（192.168.10.0/24），上面有三台路由器。本文定下
它们各自的职责、地址怎么划、AS 怎么分，新网段、新 VIP、新 BGP 邻居都按这里来。
地址与 AS 的数据在 [`ipam.yml`](ipam.yml)，由 `infrastructure/dns/generate.py` 校验。

**IPv4 是完整规划；IPv6 只有暂定方向（见文末），未实施。** WAN 没有 IPv6 接入。

## 路由职责

| 设备 | 职责 | 不做什么 |
|---|---|---|
| NEC IX（192.168.10.1，AS65000） | 出口、LAN 默认网关与 DHCP；BGP 只与路由器建邻居，按邻居过滤入方向 | 不承载内部服务路由，不直接和业务主机建 BGP |
| VyOS（VM 100，192.168.10.2，对内 AS65002） | 内部路由核心：SDN VNet 网关、VIP（LB 主机经 BGP 宣告）、dn42/OCI overlay；只向 IX 宣告汇总 | 不再新增 HAProxy 服务或手工 VIP |
| laptop FRR（192.168.10.127，AS65001） | 向 IX 宣告 NAIST 前缀（既有特例） | 不扩展成新的路由角色 |

**路由协议只用 BGP，OSPF 退休。** 三台路由器在同一个二层上，去 VyOS 后面只有一条路，OSPF
的拓扑计算与切换无从发挥；BGP 则让将来的第二台路由器只需再建一个 IX 邻居就能冗余，不必依赖
VRRP。IX 只支持 2 字节 AS（不宣告 4-byte AS capability），所以 VyOS 对内邻居一律以
`local-as 65002 no-prepend replace-as` 出现，dn42 的 4242421811 只留在 dn42/OCI 边界。

约束与取舍：

- **IX 的路由预算是个位数。** 规格上限不是约束：IX2215 的 BGP4 支持 64 个 peer、4,096 条
  路由，路由表默认 2,048 条（`ip max-route` 可扩）。约束是它作为出口的转发与 CPU 余量，表越大
  越吃性能，所以只收汇总前缀：内部地址、外部 overlay、NAIST；
  不收单个服务的 /32，VIP 增删不应改变它的路由表。VyOS 只宣告 `10.60.0.0/14`、
  `10.0.0.0/24`（OCI）、`172.20.0.0/14`（dn42）三条汇总，IX 的入方向过滤只放行这三条；
  laptop 只放行 NAIST 两条。
- **LAN 主机访问内部地址多绕一跳，接受。** 普通 LAN 主机的网关是 IX，去程 IX → VyOS，
  回程 VyOS 直接回 LAN。不为此把 LAN 设备的网关改成 VyOS。
- **因此 IX 与 VyOS 都不得对 LAN↔内部地址的流量做状态过滤。** 上述来回路径不对称，
  stateful 过滤只看到单向，会丢包。2026-10-15 核对：IX 的 LAN 口没有 `ip filter`/SPI，VyOS
  未配置 firewall。将来 retronet 的防火墙策略只限定在 retronet 出口方向。
- **VyOS 是内部地址的单点。** 它只有 PVE HA 重启（约 1–3 分钟）；内部服务越多越关键。
  第二台路由器与 IX 再建一个 BGP 邻居、宣告同样的汇总即可冗余，是已知风险，计划处理；
  届时按 [router.md](router.md) 的设计用 Debian + FRR 搭两台，VyOS 退役。
  VyOS 宕机时汇总被撤回，IX 会把去内部地址的包按默认路由送往 ISP；可在 IX 上加高管理距离
  的 null 路由兜底（`ip route 10.60.0.0/14 Null0.0 distance <n>`）。

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
65100–65199 Ayatori LoadBalancer（每个环境一个 AS，同环境主机共用）。
VyOS 的 BGP 实例使用 dn42 的 4242421811；对 IX、LB 主机等内部邻居以 `local-as` 显示为 65002，
内部邻居都是 eBGP。

LB 主机接入 VyOS：

- **环境由 AS 区分，不由主机地址区分。** 每个环境一个 peer-group（remote-as 为该环境的 AS，
  VyOS 侧 local-as 65002），
  入方向只收该环境 VIP 段内的 /32；LB 主机地址照常从 labnet `--next-free` 分配。
- **邻居是静态的，每台 LB 主机一行。** 不用 dynamic neighbor：listen range 覆盖 labnet 时，
  任何 labnet 主机（包括跑不可信负载的 sandbox 节点）都能报上 LB 的 AS 劫持 VIP；TCP-MD5
  又要在 LB 节点上放共享密钥。加 LB 主机是低频操作，改一次 VyOS 可以接受。
- VIP 明细只留在 VyOS 上，不向 IX 宣告：`10.60.0.0/14` 汇总已经覆盖 VIP 段。

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

## IPv6（暂定方向，未实施）

WAN 没有 IPv6，因此 IPv6 只在内部使用，地址取本站 dn42 ULA `fdd0:98df:15b0::/48`：

- **每个二层一个 /64，SLAAC。** LAN、labnet、retronet 各从 /48 切一个 /64，登记进 `ipam.yml`。
  不要求主机改内核参数：主机照常接收 RA、自动配地址和默认路由。
- **内部路由器（VyOS，将来的 `homelab_router`）是唯一的 IPv6 网关。** 它在各网段发 RA 并作为
  默认路由器；IX 在 LAN 上不得再以默认路由器身份发 RA（router lifetime 0 或关闭 RA）。
- **网关只放行内部与 NAIST，其余一律拒绝。** 目的为 `fdd0:98df:15b0::/48`、dn42（`fd00::/8`）
  正常路由；NAIST 的 `2001:df3:540::/48` 经 laptop tun0；其余目的地址用 `unreachable` 路由
  （或 nftables `reject`）**立即回 ICMPv6 不可达**，不得静默丢弃——静默丢弃会让连接卡在
  SYN-SENT，正是现在 `.NET`/`pwsh` 挂住的原因。
- **公网目的仍走 IPv4。** 只有 ULA 源地址时，RFC 6724 / glibc 默认表因标签不匹配优先选 IPv4；
  个别直接尝试 IPv6 的程序会立刻收到不可达并回落。需在主要发行版上实测一次。
- **NAIST 只认它分给 laptop 的地址。** VPN 只给 laptop 一个地址而不是一段前缀，NPTv6 要求
  两侧前缀等长、1:1 映射，做不了；其他主机用 ULA 访问 NAIST IPv6 需要 laptop 在 tun0 出口做
  NAT66（nftables masquerade）。若只有 laptop 自己需要，就不做，网关对 NAIST 段也直接拒绝。
- **开启了 forwarding 的主机（laptop、k3s 节点、docker 宿主）默认不收 RA**（`accept_ra` 在
  forwarding=1 时视为 0）。这些主机本来就由 Ansible/Chef 管理，统一设 `accept_ra=2`，
  不是逐台手改。

接入真正的 IPv6 时，ULA 部分保持不变（地址稳定、内部服务继续用它），只调整默认路由器：

- **LAN：** IX 正常发 RA，带公网前缀并作为默认路由器；内部路由器在 LAN 上的 RA 改为 router
  lifetime 0（继续通告 ULA 前缀供 SLAAC，但不再做默认路由器），否则主机会把公网流量交给只会
  拒绝的内部路由器。IX 加一条 `fdd0:98df:15b0::/48` 指向内部路由器的路由（LAN 主机去其他网段的
  ULA 流量经 IX 多绕一跳，与 IPv4 一致）。
- **VNet：** 内部路由器仍是默认路由器，自己的默认路由改指 IX。VNet 的公网前缀取决于 IX：ISP
  支持 DHCPv6-PD，但 IX 能否把委派到的前缀再切一段给内部路由器（再委派，或静态路由一个子前缀），
  能切多大，都未测试过——IX 的 IPv6 功能整体没有充分验证。切不出来时 VNet 只用 ULA。
- **公网前缀按静态处理。** 日本 ISP 委派的前缀通常长期不变，所以子前缀直接静态写进 IX 与内部
  路由器的配置，不做动态再委派；另加监控在委派前缀变化时告警（接入现有 Prometheus 告警，
  而不是单独的脚本），变化后手动改配置。
- 主机同时有 ULA 和公网地址，RFC 6724 会让内部目的用 ULA、公网目的用公网地址，不需要额外配置。

## 与规划不符的现状（迁移清单，未执行）

1. ~~OSPF 退休，改为 BGP~~（2026-10-16 完成）。VyOS 与 IX 以 eBGP 互联（VyOS 侧 local-as
   65002），VyOS 只发三条汇总（`IX-OUT`）、不收（`IX-IN`，默认路由仍是静态）；IX 侧
   `distribute-list vyos-in in` 只收这三条。laptop 经 IX 学到汇总，下一跳保持 192.168.10.2
   （IX 不改写第三方下一跳），所以无需与 VyOS 单独建邻居。VyOS、IX、laptop 上的 OSPF 已删除。
   VyOS 自身的 dn42 段 172.21.111.160/27 不单独宣告，由 OCI 学来的 172.20.0.0/14 覆盖：
   OCI 是去 dn42 的唯一出口，会话断开时这个段本来就没有意义，随汇总一起撤回是对的。
2. **VyOS 上的 HAProxy 服务**：sandbox-postgresql（10.60.0.1:5432）待迁到 Ayatori LoadBalancer。
   ~~sandbox-k3s-api 与 opensandbox-api（10.60.0.13）~~（2026-11-03 完成）：已迁到 `sandbox/k8s`，
   客户端经 `sandbox-k8s.lab.ddupan.top` 的 CNAME 访问。
3. **pg-prod 解析到 VyOS（192.168.10.2）。** 随上一条一起改为 VIP。
4. ~~IX 的 laptop 邻居未过滤~~（2026-10-16 完成）：IX 对 laptop 用入方向 prefix 过滤，只收 NAIST 两条。
5. **docker 自动分配会撞 dn42。** docker 默认地址池含 172.17–172.31，laptop 已自动用到
   172.18/172.19，下一个自动网络就是 172.20.0.0/16，与 dn42 路由重叠。在 laptop 的
   `daemon.json` 设 `default-address-pools`，指向一个登记过的 host-local block。
6. ~~ayatori-dev/prod LXC 在 LAN~~：它们在 laptop 的 Incus 上，只能接 LAN，符合规划，不迁移。
7. **IX 在 LAN 上发 RA**（`ipv6 nd ra other-config-flag`、DHCPv6 server）。在 IPv6 方向落地前
   不动；落地时改为不再充当默认路由器。laptop 上"有 v6 默认路由却没有全局地址"的现象见
   仓库根 CLAUDE.md，与此一并处理。
