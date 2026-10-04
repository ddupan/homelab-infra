# VyOS ↔ OCI：WireGuard 与 DN42 内部 BGP

站点端已从 laptop 迁移到 VyOS `192.168.10.2`。VyOS 位于双层 NAT 后，主动连接
`oci-amd.ddupan.top:51820`，keepalive 25 秒；LAN 访问 DN42 时在 VyOS 做定向 masquerade。
主机配置由 Ansible 管理；OCI NSG、VNIC 转发和 VCN 回程路由由旁边的 Terraform 管理。

| 节点 | 接口 | 传输 IPv4 | 传输 IPv6 | ASN |
|---|---|---|---|---|
| VyOS | wg42 | 172.21.111.161/32 | fe80::1811:1/64（BGP） | 4242421811 |
| AMD | wg-oci | 10.255.254.1/30（历史传输地址） | fe80::1811:2/64（BGP） | 4242421811 |

AMD 显式设置 `fe80::1811:2/64`；VyOS BGP 使用固定 `fe80::1811:1/64`，双方 AllowedIPs 包含
`fe80::/64`。FRR 在 ULA 建邻时仍需接口具有 link-local 下一跳地址。

MTU 1380，Linux 使用 `Table = off`，WireGuard AllowedIPs 用于选 peer 与源地址校验，
站点路由由 iBGP 安装。内外部均使用单条 IPv6 link-local 会话承载双 AFI，并启用 extended-nexthop。
内部旧 IPv4/ULA BGP 邻居已退役；ULA 传输地址保留用于路由下一跳，不再用于建邻。
VyOS 10.2.4 通过 `OCI-MP-IN` 的 `ipv6-next-hop prefer-global` 优先采用通告中的 ULA 下一跳，
避免 link-local NHT 显示 overlay index unresolved、BGP 已建邻但路由未安装。

## 地址与通告边界

已注册 `172.21.111.160/27`、`fdd0:98df:15b0::/48`：

| 节点 | 路由器 IPv4 | 路由器 IPv6 |
|---|---|---|
| VyOS（IPv4 在 wg42，IPv6 在 lo） | 172.21.111.161/32 | fdd0:98df:15b0::1/128 |
| AMD loopback | 172.21.111.162/32 | fdd0:98df:15b0::2/128 |

VyOS 为注册的 /27、/48 建立 distance 254 的 blackhole 聚合路由，保证精确前缀存在，
避免未分配地址落入默认路由。已分配的本地地址及 AMD 的 /32、/128 优先于聚合。

内部通告严格过滤：

- VyOS → AMD：`192.168.10.0/24`、`10.60.0.0/24`、`10.61.0.0/24` 和注册 /27、/48。
- AMD → VyOS：`10.0.0.0/24`、AMD 的注册 /32、/128，以及 DN42 汇总 `172.20.0.0/14`、`fd00::/8`。
- VyOS 向 LAN OSPF 只重分发 OCI /24、DN42 /14 和注册 IPv4 /27，使用精确 route-map、E1 metric。
  既有直连 LAN/SDN 的 OSPF area 声明保持不变，不使用泛化的 redistribute connected。

**首个外部 peer 为 RoutedBits Osaka（AS4242420207），由 `dn42.yml` 单独管理。** 外部邻居使用独立的 import/export
过滤，只对外通告注册 /27、/48；禁止把上述内部业务前缀的过滤器复用到外部邻居。
入口使用 DN42 指南的保留地址、互联网络与前缀长度规则（IPv6 /44–/64），
并优先拒收本 AS、LAN、OCI 前缀；尚未配置注册表 ROA 校验。外部明细留在 AMD，汇总通过 iBGP 下发 VyOS；IPv4 汇总再经 OSPF 下发 LAN。

每个外部 WireGuard peer 使用独立接口，BGP 可复用本机 loopback 地址。
单接口多个 WireGuard peer 要求可明确区分的 AllowedIPs；多家 peer 都提供同一 DN42 路由范围时，
使用独立接口让 BGP 决定出口，避免相同 AllowedIPs 抢占 peer。

## 执行

```bash
cd infrastructure/oci/ansible
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook site.yml  # 复跑应 changed=0
```

`vyos.yml` 先在路由器本机生成密钥并保存，再交换公钥并增量应用 VyOS set 命令。
VyOS native config 含私钥，因此相关模块使用 `no_log`，不把配置备份到 Git 或打印出来。
AMD 私钥在 `/etc/wireguard/wg-oci.key`（0600），由本机 PostUp 加载，不返回控制机。
首次 check mode 无法生成私钥，因此会跳过依赖不存在公钥的 Linux 配置渲染。

`retire-laptop.yml` 是迁移收尾：先检查 VyOS 邻居，再停止 laptop 的 wg-oci，
删除试验邻居、三个新增 network 语句及专用防火墙链，保留 laptop 原 AS65001 ↔ NEC AS65000
会话、原有 VPN 路由和 OSPF。旧私钥保留在 laptop 受限文件中，隧道和防火墙单元已禁用。

Linux 端 FRR 通过 `vtysh -f` 应用独立配置片段，另行 `write memory` 持久化；
文件变更时重建受管邻居，未变更的重跑不重置会话。移除前缀时还须显式删除已退出管理的
`network` 语句，不能只追加 set 命令，也不能清空整份 BGP 配置。

## OCI 回程与 Tailscale

VCN 虚拟路由器不参与主机间 iBGP；三个家中业务前缀的静态回程指向 AMD Private IP OCID。
首次启用时必须先将 VNIC `skip_source_dest_check` 设为 true，OCI 才接受该私有 IP 为路由目标。
当前 Terraform 的 route table → subnet → instance 依赖使首次引导需要先设置该标志。
重建 AMD 后须重新查询并更新 `amd_router_private_ip_ocid`。

ARM 接受 Tailscale 家中子网路由，table 52 原本抢走回程。
Ansible 在 ARM 设置 priority 5101–5103、仅匹配这三个目的前缀的 `lookup main` 规则，
让这些流量使用 OCI 网关→AMD；其他 Tailscale 地址保持原路径。
AMD 的 Zebra route-map 仅为本机发起的 BGP 业务流量选择 `10.0.0.158` 源地址，不改写转发源地址。

## Docker 地址冲突

DN42 使用 `172.20.0.0/14`。原 laptop Docker 的四个 /16 已清除，默认池改为 `172.28.0.0/16`，
详见 [Docker runbook](../../docker/README.md)。最长前缀匹配决定路由，但不能解决两套网络实际
地址重叠；不能只检查本 AS 注册的 /27 而忽略其他 DN42 注册前缀。

## 验证与停用

```bash
# VyOS operational mode
show interfaces wireguard wg42 summary
show bgp summary
show ip route 172.21.111.162/32
show ipv6 route fdd0:98df:15b0::2/128
# AMD
sudo wg show wg-oci latest-handshakes
sudo vtysh -c 'show bgp summary'
ping 192.168.10.4
ping -I 172.21.111.162 172.21.111.161
ping -6 -I fdd0:98df:15b0::2 fdd0:98df:15b0::1
```

业务网段测试应使用业务源地址；DN42 loopback 测试使用注册地址。
LAN 已通过 `dn42-ra.yml` 部署 DN42 SLAAC 与专用 RIO，不发布 IPv6 默认路由；OCI VCN 保持原配置。
停用或回滚须同时处理 BGP、WireGuard、OSPF 重分发、VCN 回程和 ARM 例外规则，
不能仅停止隧道后留下静态回程指向不可达节点。

参考：[WireGuard](https://www.wireguard.com/quickstart/)、
[VyOS WireGuard](https://docs.vyos.io/en/1.5/configuration/interfaces/wireguard.html)、
[DN42 入门](https://www.dn42.dev/howto/Getting-Started)。

## 迁移验收

2026-09-14：

- VyOS IPv4 iBGP 收到 OCI /24、AMD /32，通告三个家中前缀与注册 /27；IPv6 会话双方各收到一条前缀。
- 两端 DN42 loopback IPv4、IPv6 互通；IPv6 本次采样约 3.1 ms。
- laptop 的 `10.0.0.0/24` 与 `172.21.111.160/27` 经 OSPF 指向 `192.168.10.2`，不再使用旧隧道。
- PVE1 可访问 ARM 私网和 AMD 的 DN42 IPv4；AMD 可访问 PVE1、`10.60.0.1`、`10.61.0.1`。
- laptop 旧 WireGuard 和专用防火墙 service 已停止/禁用，原 NEC BGP 会话保留。

LAN 网关可能返回 ICMP Redirect，提示客户端将 VyOS 作为同网段下一跳；这是既有 LAN
拓扑的正常结果，没有为此修改客户端或网关的 redirect 策略。

## AMD 外部 DN42 首个接口

2026-09-15 已通过 `ansible-playbook dn42.yml` 准备独立监听：

- 接口：`wg-dn42-1`，UDP endpoint：`oci-amd.ddupan.top:51821`（`129.225.176.134:51821`）。
- 公钥：`YQ/X3QmNocnr0u4aUm5qhcV328StSNtg+ULd9AKCdhQ=`。
- 私钥仅保存在 AMD `/etc/wireguard/wg-dn42-1.key`，由 root 受限目录保护，不返回控制机。
- `wg-quick@wg-dn42-1` 开机启动；主机入站规则随接口启停，OCI NSG 规则由 Terraform 管理。
- Link-local：`fe80::1811:2/64`，本机作用域为 `%wg-dn42-1`。首个 peer 使用单条 IPv6 BGP 会话承载双栈（MP-BGP + RFC 8950 extended next hop）。
- 对端：AS4242420207，`router.osa1.routedbits.com:51811`，link-local `fe80::207`。
- 对端公钥：`96PwUEGi/ijdmKO+IjuZ+J6DeykuTRukZD5atajfeH4=`。
- WireGuard 使用 `Table = off`；AllowedIPs 为 `fe80::/64, 172.20.0.0/14, 10.0.0.0/8, 172.31.0.0/16, fd00::/8`，keepalive 25 秒。
- 双 AFI 共用 IPv6 TCP 会话并启用 extended-nexthop；每 AFI maximum-prefix 10000，出口只允许注册 /27 和 /48。
- 本机发起 DN42 流量使用注册地址作为 preferred source，不做 NAT。
- Ubuntu 自带 FRR 8.4.4 不满足 [DN42 FRR 指南](https://dn42.dev/howto/frr) 的 link-local 版本要求。
  `tasks/frr-dn42.yml` 使用官方 frr-10.7 软件源，固定 10.7.1；升级前配置仅在 AMD `/var/backups/frr-before-dn42` 备份。

原 `wg-oci:51820` 继续承载与 VyOS 的内部互联。

2026-09-15 接入验收：WireGuard 握手与 `fe80::207%wg-dn42-1` 连通；FRR 10.7.1
会话 Established，双方已协商 IPv4/IPv6 AFI 与 extended nexthop。采样接收 IPv4 1174、IPv6 1273 条，
对外仅通告 `172.21.111.160/27`、`fdd0:98df:15b0::/48`。AMD 无需显式指定源地址，
即可访问对端 `172.20.19.78`、`fdb1:e72a:343d::f`，各 3/3 回复，约 1 ms；
IPv4 内核路由下一跳为 `via inet6 fe80::207 dev wg-dn42-1`。内部 VyOS 双栈 BGP 会话已恢复。

## 向 LAN 分发 DN42 汇总

`site.yml` 在 AMD 生成 `172.20.0.0/14`、`fd00::/8` 的 BGP aggregate，并通过内部精确
prefix-list 通告 VyOS。不使用全局 `summary-only`，避免抑制对外通告的注册 /27、/48；
对外出口过滤仍只允许这两个注册前缀。AMD 保留外部明细与汇总丢弃路径，无匹配明细的流量
在 AMD 丢弃。汇总只要仍有覆盖的 BGP 明细（包括本 AS 注册前缀）就可能存在，不能作为外部
peer 在线状态指示。自己的 /27、/48 更具体，继续指向本地站点。

VyOS 将 IPv4 /14 通过既有 OSPF E1 分发到 LAN；IPv6 /8 通过 RA 的 RIO 分发至接受该选项的客户端。
LAN 的 DN42 IPv6 地址通过 SLAAC 自动分配。
当前 LAN IPv4 客户端访问 DN42 /14 由 VyOS 定向 masquerade 到 `172.21.111.161`；
IPv6 使用 SLAAC 分配的注册地址直接路由。
AMD 只放行注册前缀在内部 `wg-oci` 与外部 `wg-dn42-1` 之间转发。

2026-09-15 汇总验收：VyOS 双栈 BGP 分别收到 /14、/8，下一跳为 AMD；
laptop 的 `172.20.0.0/14` 为 OSPF 路由，经 `192.168.10.2 dev br0`。
使用 VyOS 注册的 /32、/128 作为源，经 AMD 访问 RoutedBits 的双栈地址各 3/3 回复，
约 4–5 ms。`site.yml` 执行成功，ARM 无变更；LAN 地址配置保持原状。

## DN42 DNS 转发

`ansible-playbook dn42.yml dn42-dns.yml` 管理入口路由和 VyOS DNS。LAN 的 Blocky
(`192.168.10.127`) 将 `.dn42`、172.20–23 的 IPv4 反向区和 `d.f.ip6.arpa`
转给 VyOS `192.168.10.2:53`。VyOS 仅接受三个内部 LAN 网段，使用注册地址
`172.21.111.161` / `fdd0:98df:15b0::1` 发起递归转发，不做 NAT。

| 上游 | IPv4 | IPv6 |
|---|---|---|
| a0.recursive-servers.dn42 | 172.20.0.53 | fd42:d42:d42:54::1 |
| a3.recursive-servers.dn42 | 172.23.0.53 | fd42:d42:d42:53::1 |

两个上游的双栈地址均配置，递归请求设置 RD；转发域配置 NTA，避免使用公网根信任链
验证 DN42 私有命名空间。本地转发器不声明已完成 DN42 DNSSEC 信任锚验证。
IPv4 anycast /32 需要允许四个 `172.2x.0.0/24` 中的 /28–/32，不能只保留 /14 的 /21–/29。
新增互联网络明细仅由 AMD 接收；LAN 汇总仍是既定 /14、通过 RIO 通告的 IPv6 /8。
NEC 备用 DNS 与 k3s CoreDNS 本次未修改。

DNS 验收（2026-09-15）：从 VyOS 用注册地址直查 a0/a3 的四个双栈地址均获得回复。
LAN 查询 Blocky 可得到 a0 的 A、a3 的 AAAA；AD 与公网域名正常，Blocky healthy。
VyOS DNS playbook 复跑 changed=0；AMD 已应用完整入口规则。

## VyOS LAN 到 DN42 masquerade

规则 18100 排除本 AS `172.21.111.160/27`；18110、18120、18130 分别匹配三个 LAN
源网段，目的仅 `172.20.0.0/14` 且出口 `wg42`，translation 为 `masquerade`。
为使 masquerade 选中注册地址，`172.21.111.161/32` 从 lo 移到 wg42，并移除
`10.255.254.2/30`；不能在 wg42 仍以传输私网地址为主 IPv4 时直接启用 masquerade。
现有 OCI 业务互联继续保留原源地址，DNS 转发使用的 `172.21.111.161` 保持可用。
AMD 仍仅允许 DN42 注册源前缀进入外部隧道，不在 AMD 做第二次 NAT。

2026-09-15 masquerade 验收：laptop `192.168.10.127` 到 RoutedBits `172.20.19.78`
3/3 回复约 4.7 ms，VyOS NAT 表显示转换为 `172.21.111.161`；到 ARM `10.0.0.124`
3/3 回复约 4.2 ms，NAT 表确认保留 `192.168.10.127`。
内部 link-local 单会话双 AFI 已建立；外部 peer 保持独立接口和精确出口。

## LAN DN42 IPv6 RA（不发布默认路由）

执行 `ansible-playbook dn42-ra.yml`，为三个 LAN 启用 SLAAC：

| LAN | VyOS 接口 | 前缀 | 路由器地址 |
|---|---|---|---|
| 192.168.10.0/24 | eth0 | fdd0:98df:15b0:10::/64 | fdd0:98df:15b0:10::1 |
| 10.60.0.0/24 | eth1 | fdd0:98df:15b0:60::/64 | fdd0:98df:15b0:60::1 |
| 10.61.0.0/24 | eth2 | fdd0:98df:15b0:61::/64 | fdd0:98df:15b0:61::1 |

Router Lifetime 为 **0**，不发布 `::/0`；PIO 开启 on-link 与 autonomous 标志，
preferred lifetime 14400 秒、valid lifetime 86400 秒。RIO 只包含 `fd00::/8`，
有效期 180 秒；RA 周期 10–30 秒。不发布 RDNSS、DNSSL、DHCPv6 标志或链路 MTU，
保留客户端现有 DNS 和公网出口。IPv6 经 VyOS→AMD→DN42 直接路由，不做 NAT66。
现有 /48 对外通告及内部回程已覆盖这三个 /64，无须泄漏每个 LAN 的明细到外部。

客户端须支持并接受 RIO。当前 laptop 的 br0 `accept_ra=0`、`forwarding=1`，
不会自动配置；本次保留其网络设置。Linux 路由主机如需接受 RA，需要在自身网络管理
配置中显式启用，并允许至少 /8 的 RIO（`accept_ra_rt_info_max_plen`）。
关闭 RA 时注意 PIO 的有效期；不要只删路由器接口地址而留下仍有效的客户端地址。

2026-09-15 RA 抓包验收：主 LAN 收到不带标签的 `:10::/64`；VLAN 100/110
分别携带 `:60::/64`、`:61::/64`。三者 Router Lifetime 均为 0，PIO 为 onlink/auto，
RIO 为 fd00::/8、180 秒，没有 DNS 或默认路由通告。`dn42-ra.yml` 复跑 changed=0。
同一 LAN 上的临时 Linux 测试客户端自动获得地址与 RIO，无 IPv6 默认路由；测试后自动删除。

## oci-arm 外部看守（`watcher.yml`）

laptop 是整个 lab 的单点，同时也是监控栈所在地：它挂了，"没有告警"和"一切正常"无法区分。
oci-arm 上跑一套独立的 Prometheus + Alertmanager + blackbox_exporter（Ubuntu 包），自己发
Telegram，与 laptop 不共享任何组件。

**dead-man**：laptop 的 vmalert 有一条永远在响的 `Watchdog`（severity none，laptop 的
Alertmanager 把它丢进 blackhole），同时经 Tailscale 推给 `100.99.94.44:9093`。oci-arm 上
`LabWatchdogMissing` 也永远在响，但被 Watchdog **抑制**。vmalert 给每条告警的 `endsAt` 是
发送时间 + 4×评估间隔（约 2 分钟）；Watchdog 停止到达后抑制解除，约 2–7 分钟内发出告警。
能发现：laptop 离线、k3s / monitoring 命名空间故障、vmalert 停止、VMSingle 查询失败
（`vector(1)` 也要经它执行）、laptop ↔ oci-arm 的 Tailscale 中断。恢复后告警重新被抑制，
**不会发"已恢复"**。

**其余职责**：

- 经 Cloudflare 从外部探测公网入口（auth / git / e5renew / obj），持续 10 分钟失败才报，
  因为家宽本身会随机掉线。
- 代发 laptop 告警链路自身的故障（`AlertmanagerTelegramDeliveryFailed` 等）：laptop →
  Telegram 坏了的时候，由 laptop 自己发等于没发。laptop 推过来的其余告警一律丢弃，避免重复。

**暴露面**：Prometheus、blackbox 只听 `127.0.0.1`；Alertmanager 只听 Tailscale 地址，
gossip 端口（默认 `0.0.0.0:9094`）显式关闭。开机时 tailscale0 还没地址会绑定失败，
drop-in 让它排在 tailscaled 之后并无限重试，不退回到 `0.0.0.0`。

**执行**（需要 `hvac`，见 CLAUDE.md 的 uv 安装命令）：Telegram token 从 Bao
`kv/k8s/alertmanager` 读取，控制机上要有 `VAULT_TOKEN`（SPIFFE `local-development` 角色可读）。

```bash
cd infrastructure/oci/ansible
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
VAULT_TOKEN=... ansible-playbook watcher.yml --check --diff
VAULT_TOKEN=... ansible-playbook watcher.yml
```

⚠ **顺序**：先合并 laptop 侧（Watchdog 规则 + vmalert 第二个 notifier），再部署 oci-arm；
反过来 `LabWatchdogMissing` 会立刻发到生产频道（2026-10-04 首次部署就这样发了一条）。
维护 laptop 监控栈期间，在 oci-arm 上 `amtool --alertmanager.url=http://100.99.94.44:9093
silence add alertname=LabWatchdogMissing` 临时静默。
