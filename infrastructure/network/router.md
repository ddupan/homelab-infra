# 下一代路由器设计（未实施）

替换 VyOS 的目标形态。只是设计：触发点是"需要第二台路由器"，届时两台都按本文搭建，
VyOS 一并退役。现状与约束见 [README.md](README.md)。

## 为什么换

- VyOS 的 LTS 源码与软件包已不公开，只剩季度发布的 Stream，升级可能改语法。
- 现有 IaC 是 `vyos_config` 推 `set` 行：只会追加，删不掉旧值，多值节点改不了。
- VyOS 底层本来就是 Debian + FRR + nftables + Kea；去掉它那层 CLI，换来整份文件、
  可声明、可测试的配置。

不选 RouterOS CHR（闭源、厂商依赖）、SR Linux（面向 DC 交换，容器版有授权限制）、
VPP（节点网卡 I219-V/RTL8111 不支持 DPDK，1G 链路上没有收益）。FRR 的 YANG northbound 对
bgpd 尚未完成，暂不依赖。

## 组成

| 功能（现在在 VyOS 上） | 新实现 | 配置方式 |
|---|---|---|
| 接口：LAN、labnet、retronet | systemd-networkd | Chef 渲染 `.network`/`.netdev` |
| BGP：IX、LB 主机、OCI/dn42 | FRR bgpd | Chef 渲染完整 `frr.conf`，`frr-reload.py` 应用差异 |
| wg42（到 OCI 的 dn42 传输） | WireGuard（networkd netdev） | 私钥运行时取（见"秘密"） |
| dn42 SNAT、retronet 出口策略 | nftables | 整份规则集，`nft -f` 原子替换 |
| VNet DHCP | Kea DHCPv4 | 整份 JSON；两台用 Kea HA hot-standby |
| VNet 网关冗余 | keepalived（VRRP） | Chef 渲染 |
| 节点监控 | homelab_base 的 node_exporter + frr_exporter | Chef |
| HAProxy 服务 | 不迁移，届时已在 Ayatori LoadBalancer 上 | — |

模型放在 Chef custom resource 的属性上（邻居、AS、prefix-list 有类型和取值校验），模板只是
实现细节；ChefSpec 断言"给定模型渲染出什么"，Kitchen 在容器里起 FRR 验证配置可加载、二次
converge 零变更。同 LB 主机的 `homelab_loadbalancer` 一样，这是新 cookbook `homelab_router`。

数据从 [`ipam.yml`](ipam.yml) 来：网段、VLAN、AS 在那里登记，homelab-infra 的 policy 属性
引用这些值，不在 cookbook 里写死。

## 冗余

两台 VM（`router-1`、`router-2`），放在不同 PVE 节点，本地存储，不进 PVE HA——冗余在应用层，
HA 重启只会和它抢。

- **对 IX：** 两台各与 IX 建 eBGP（对内 AS 各自一个私有 AS 或共用 65002），宣告相同的三条汇总；
  IX 开 `multipath` 或主备均可。一台宕机，BGP 撤路由，IX 切到另一台，不需要 VRRP。
  IX 不支持 BFD，靠调小 BGP hold timer（如 keepalive 3s / hold 9s）缩短检测时间。
- **对 VNet 主机：** 主机的网关是固定地址（10.60.0.1、10.61.0.1），只能靠 VRRP 漂移。
  两台在各 VNet 接口上跑 keepalived，虚拟地址即现在的网关地址，主机侧无需改动。
- **对 LB 主机：** 每台 LB 主机与两台路由器都建邻居，任一路由器在，VIP 就可达。
- **对 OCI/dn42：** 每台路由器一条自己的 wg 隧道和 MP-BGP 会话（OCI 侧加第二个 peer）。
  SNAT 状态不跨路由器同步，切换时进行中的 dn42 连接会断，接受。

切换期间的不对称路径（经 IX 进、VRRP 主机出）沿用 README 的约束：路由器不对 LAN↔内部地址
做状态过滤；nftables 的状态规则只用于 dn42 SNAT 与 retronet 出口。

## 秘密

路由器节点上唯一的秘密是 wg42 私钥。不进 Chef 属性和 policy：节点经 SPIRE 拿 SVID，
启动时从 Bao 读取并写入 tmpfs，再由 networkd 引用。Chef 只管理"去哪里取"。

## 迁移（届时执行）

1. 建 `router-1`，只接 LAN，与 IX 建 BGP 但先不宣告；Kitchen 与 why-run 验证。
2. 接 OCI：OCI 侧加第二个 wg peer，`router-1` 建隧道与 MP-BGP，确认 dn42 路由双路径可用。
3. 接 VNet：`router-1` 加入 labnet/retronet，以低优先级跑 VRRP；VyOS 释放 10.60.0.1/10.61.0.1
   的同时 `router-1` 接管（短暂中断，安排窗口）；DHCP 从 VyOS 切到 Kea。
4. LB 主机加 `router-1` 邻居；`router-1` 向 IX 宣告汇总。
5. 建 `router-2`，重复 1–4，VRRP 与 Kea HA 成对。
6. 撤掉 VyOS 的 BGP 与地址，关机保留一段时间后删除 VM 100。

## 未决

- 两台路由器对 IX 用同一个 AS 还是各自一个：共用便于 IX 侧过滤写一份，各自便于排障。
- 实现用 Chef（上文）还是 NixOS，见下节，届时再定。

## 备选：NixOS（2026-11-04 评估，未定）

三者的区别不在"能否声明式"，而在**改坏之后多快、多平稳地回到上一版**：

| | 回滚 | 回滚时的扰动 | 正确性靠什么 |
|---|---|---|---|
| VyOS | `commit-confirm`，超时未 `confirm` 自动回退 | **默认 `action reboot`**（重启进 saved 配置）；设 `system config-management commit-confirm action reload` 才是不重启的差异回退 | commit 时的配置树校验 |
| NixOS | deploy-rs magic rollback：激活后放 canary，`confirmTimeout`（默认 30s）内控制端未确认就在线重新激活上一代，**不重启** | FRR 走 reload（见下），会话不断；其他 unit 若配置变了会被 restart | 事前检查（CI 构建整机、flake check） |
| Chef | 无自动回滚：revert 提交，CI 重新 converge，分钟级；锁死自己只能上 console | `frr-reload.py`，会话不断 | 事前测试（ChefSpec、Kitchen、why-run） |

NixOS 回滚**不等于重启**：只有内核/initrd 变了，或机器起不来要在启动菜单选旧代时才需要。

**nixpkgs 的 FRR 模块**（`nixos/modules/services/networking/frr.nix`，FRR 10.7.1，读代码确认，未实机验证）：

- `reloadIfChanged = true`，`restartTriggers = [ configFile daemonList ]`：`frr.conf` 或启用的
  daemon 变化时，switch 执行 `systemctl reload frr` 而非 restart。
- `ExecReload` 是 FRR 自带的 `frrinit.sh reload`：重启 watchfrr 以接管新增 daemon（其余 daemon
  不重启），再 `frr-reload.py --reload` 应用整份 `frr.conf` 的差异——与上文 Chef 方案同一机制。
- ⚠ `frrinit.sh reload` 最后无条件 `exit 0`，**`frr-reload.py` 失败也报成功**。坏的 `frr.conf`
  会被当作激活成功：auto rollback 不触发，SSH 仍通所以 magic rollback 也不触发，FRR 停在新旧混合
  的配置上。必须在构建期挡住：flake check 里跑 `vtysh --dryrun -f frr.conf`（对应 Chef 的 Kitchen）。
- ⚠ FRR 包升级也只触发 reload，旧 bgpd 继续运行到下次重启。升级 FRR 要在窗口里手动
  `systemctl restart frr`。

**结论**：补上 dry-run 检查后，NixOS 同时有接近 VyOS `reload` 的在线回滚和 Chef 式的事前验证；
代价是 Chef 之外再养一套语言、CI 路径和秘密注入方式（wg42 私钥可用本机生成的文件，不进 store）。
两条路都比"VyOS 整份 `load`"好：后者必须把 wg 私钥和登录 hash 渲染到控制机，且躲不开 Stream 改语法。

**GitOps：推送式，不用拉取式。** 形态同 Chef 的 `chef.yml`：

- PR：`nix flake check`（含上面的 `vtysh --dryrun`）+ 构建整机 closure + 对目标跑
  `switch-to-configuration dry-activate`，列出会 reload/restart 的 unit，贴进 PR，等价于 why-run。
- 合并：CI 跑 deploy-rs，开 magic rollback。

拉取式（comin、`system.autoUpgrade.flake`）不给 CI 部署权限，但**部署后没有基于连通性的回滚**——
comin 的 confirmer 只是部署*前*的人工/延时确认。路由器改坏就失联，正需要 magic rollback，所以推送。

CI runner 到路由器的确认路径要经过被改的转发面才有意义：确认发不回来 = 变更弄断了网 = 自动回滚。
runner 走 LAN 地址（192.168.10.x）连路由器，而不是依赖某个 VNet 网关之外的旁路。

**不论选哪条，先收拢写入方。** 整份替换意味着最后渲染的一方会抹掉其他人的配置，而现在
vyos-rtr 由六处写入：`proxmox/ansible/roles/vyos_router`、`oci/ansible/vyos.yml`、`dn42-dns.yml`、
`dn42-ra.yml`、`shared-postgresql/ansible/proxy.yml`（pg-prod HAProxy，随 Ayatori 迁移撤掉）、
`proxmox/ansible/vyos-monitoring.yml`；BGP 的 `system-as` 在 oci 侧，邻居在 proxmox 侧。迁移时
它们要并成一个拥有者和一份数据模型（取自 [`ipam.yml`](ipam.yml)），Chef 或 Nix 只是渲染后端。

已确认：IX 支持 `ip route … Null0.0 distance <n>`（高管理距离兜底路由可行）；FRR 用
`frr-reload.py` 热应用配置，只有改会话参数（timers、capability）时需要对该邻居软复位。
