# 监控覆盖缺口清单

2026-10-04 盘点：vmagent 55 个目标全部 `up`、无告警在响——但覆盖面基本只有笔记本上的
k3s、平台控制器和共享数据服务。本文件是补齐路线图：**每补一项，在同一个 PR 里勾掉并写上
PR 号**；新发现的盲区直接追加。

验收标准统一为：**能出数据 + 有对应告警规则 + 规则在 `metrics/tests/` 有单测**。只有
指标没有规则，等于没补（第 6 节的笔记本电源/systemd 就是反例：数据早就有，没人看）。

优先级：P0 = 现在坏了不会有人知道且影响全局；P1 = 关键单点；P2 = 补全；P3 = 锦上添花。

## 1. 监控自身（P0）

整套 VM 栈和它要监控的东西同在笔记本上；没有心跳时"没告警"与"一切正常"无法区分。

- [x] **M1** `Watchdog` 常驻告警 + 外部 dead-man（healthchecks.io 或 OCI 主机上的接收端），心跳断即报警 — oci-arm `watcher.yml`（Watchdog 抑制 LabWatchdogMissing）
- [x] **M2** Telegram 投递本身失败的兜底路径（现有 `AlertmanagerTelegramDeliveryFailed` 也是走 Telegram 发的） — oci-arm 代发 laptop 的 Telegram 投递失败告警
- [x] **M3** 评估：把 dead-man / 关键探测放到 lab 外（OCI），避免和笔记本同生共死 — 放在 oci-arm

## 2. 黑盒探测（P0）

`probe_success` 当前为空；集群里没有 VMProbe / blackbox-exporter。

- [x] **B1** 部署 blackbox-exporter + VMProbe 基础设施 — `metrics/probes/`；HTTP / DNS 模块，ICMP 未启用（需要 NET_RAW，目前不需要）
- [x] **B2** Envoy Gateway：逐个 Host 的健康端点 — `probes.yaml` 的 lan-https；`metrics-write` 只接受 POST，未纳入。新增 HTTPRoute 时要同步加一行
- [x] **B3** 公网入口经 cloudflared：`auth` / `git` / `obj` / `e5renew.ddupan.top` — 从 oci-arm 经 Cloudflare 探测
- [x] **B4** DNS：dc1 / CoreDNS / Blocky 解析 `dc1.ad.ddupan.top`，Blocky / CoreDNS 的 split-horizon（`git.ddupan.top` → Envoy）
- [x] **B5** VPN 黑洞：探测经 tun0 的 `www.naist.jp`，出口正常时失败即 `NaistVpnDown`。2026-09-11 起 pull-filter 只接受 NAIST 路由，CDN 不再走 tun0（CLAUDE.md 已更新）
- [x] **B6** WAN 连通性：github.com + Cloudflare 都失败 10 分钟才报 `WanEgressDown`
- [x] **B7** OpenBao `/v1/sys/health` 按主机名探测（在 lan-https 里）

## 3. Proxmox / 网络（P1）

- [x] **P1** pve1/2/3 装 node-exporter（Ansible role，进 `infrastructure/proxmox/` site.yml） — `infrastructure/proxmox/ansible/monitoring.yml`
- [x] **P2** pve-exporter：guest 状态、存储、HA 状态 — 选 prometheus-pve-exporter（PVEAuditor token 在 Bao），没用 PVE 9.2 自带 OTLP：后者无 HA/锁/节点在线视角，且只发 JSON
- [x] **P3** corosync / quorum 告警（fencing 已全集群启用，失去 quorum 会自重启） — corosync-quorumtool → textfile（`pve_corosync_*`），30 秒一次
- [x] **P4** HA 事件：`vm:100` 迁移/重启要有通知 — `pve_ha_state`：HA 资源不在 started、fence/error
- [x] **P5** LINSTOR / DRBD：controller `/metrics`（节点、volume、存储池容量、error report）+ 三节点
  drbd-reactor Prometheus 插件（连接状态、quorum、IO 挂起、out-of-sync、后端盘故障）
  - ⚠ pve2/pve3 上也在跑**空的** `linstor-controller`（0 节点 0 资源；PVE 插件与客户端只连 pve1）：
    `pve_linstor` 只在 pve1 启用 controller，却没有在其他节点停用，Debian 包安装时默认启用。真正的 controller HA（linstor_db + promoter）见 #295
  - pve1 的 `ssd` 池只剩约 18%（告警阈值 15%）
- [x] **P6** VyOS：内置 node/frr exporter（`vyos.yml`）、服务状态 textfile（`vyos-monitoring.yml`）、pg-prod HAProxy
  metrics（`shared-postgresql/proxy.yml`）、四个 TCP 入口与 DN42 DNS 探测。VyOS 远不止路由：pg-prod 生产库入口、
  sandbox k3s API、SDN 的 DHCP/RA/NTP、DN42 都在它上面
  - ⚠ VyOS **没有配置 firewall**；NTP 服务端与 syslog 配置不在任何 playbook 里（2026-10-05 发现，未处理）
  - ⚠ `infrastructure/proxmox/vyos/backups/config.boot` 曾被提交（含 `vyos` 用户的密码 hash），已改为 gitignore，
    历史未改写——建议轮换 `vyos` 密码
- [ ] **P7** NEC IX：SNMP（接口、WAN 口状态）——若设备支持
- [ ] **P8** 无线 AP：至少 ICMP 存活

## 4. 其他主机与 VM（P1–P2）

- [x] **H1** dc1（Samba AD）：node-exporter（`monitoring-dc.yml`）+ samba-ad-dc 服务、Kerberos/LDAP/LDAPS 端口、LDAPS 证书到期、samba-acme 续期 timer、时钟同步。DNS 见 B4。只有一台 DC，没有复制可监控
- [ ] **H2** libvirt-exporter：dc1 / bao1 / winadmin / win2k25 的 VM 状态
- [ ] **H3** 10.60.0.20/21（共享 PG/etcd 节点）主机层面 node-exporter（现在只有 PG/etcd 指标）
- [ ] **H4** ayatori-dev/prod（Incus .11/.12）node-exporter —— 只装 exporter，**不碰 Ayatori 本身**
- [ ] **H5** Incus 自身指标（`/1.0/metrics`）
- [ ] **H6** sandbox 集群节点 node-exporter（现在只有 kata / spire-agent）
- [ ] **H7** winadmin：windows_exporter
- [ ] **H8** OCI 两台云主机（oci-arm / oci-amd）
- [ ] **H9** retrolab（10.60.0.10，当前不在线）——在线时再决定

## 5. 笔记本本机（P1：数据已有，缺规则）

- [x] **L1** 断电告警：`node_power_supply_online == 0` / 电池电量低 —— 整个 lab 的单点在用电池跑 — #215
- [x] **L2** systemd unit failed 告警（`node_systemd_unit_state`）— #215（规则）、#219（AppArmor profile）
- [x] **L3** 温度告警（`node_hwmon_temp_celsius`）— #215。⚠ CPU 常年贴着 TjMax（7 天 p90 97°C、package
  throttle 约 278 万次/天）——这是硬件散热问题，告警只能兜底"持续达到 crit"，治本要清灰/换硅脂
- [ ] **L4** SMART / NVMe 健康（smartctl-exporter）
- [ ] **L5** NFS 服务端（nfsd 指标 + 导出可挂载探测）
- [ ] **L6** IPv6 源地址错配（`SYN-SENT` 堆积）——想清楚可观测信号再做；真正的修复是 `accept_ra=2`
- [x] **L8** 宿主机过载：load / swap 用量 / PSI（`node_pressure_*`）告警。2026-10-04 CI 构建（ko/go build） — #215
  叠加 seaweedfs、zot 重启，load 冲到 54、swap 用满 7.8/8G、IO PSI 40%+，VMSingle 查询排队超时——
  **唯一响起来的是副作用 `AlertingRulesError`**，真正的原因没有任何告警
- [ ] **L9** CI runner 资源边界：dynamic-runner 的 task Pod 与关键服务抢同一台笔记本，考虑 limits / 并发上限 / 优先级
- [ ] **L7** 清理：笔记本 node-exporter 被采了两份（`node-exporter` job 与 `docker-hosts` job 的 `:9100`）

## 6. k3s 控制面与集群组件（P2）

kube-state-metrics 的 Pod/Deployment 告警能兜住"进程挂了"，兜不住"功能坏了"。

- [ ] **K1** apiserver / scheduler / controller-manager 指标（k3s 内嵌，需开启 metrics 绑定）
- [ ] **K2** CoreDNS 指标 + 错误率告警
- [ ] **K3** Envoy Gateway：控制面 + 数据面（`envoy_*`）、5xx 率
- [ ] **K4** cloudflared 隧道指标（连接数、错误）
- [ ] **K5** Tailscale 子网路由器健康
- [ ] **K6** SPIRE server 指标
- [ ] **K7** OpenEBS ZFS（zpool 健康已有，补 CSI 侧）

## 7. 应用（P2）

- [ ] **A1** Authelia（SSO 前门；注意它在退役计划中，先确认是否值得做）
- [ ] **A2** Gitea（CI 与 GitOps 源头）
- [ ] **A3** Nexus
- [ ] **A4** zot
- [ ] **A5** iam-login
- [ ] **A6** smtp-relay（Postfix 队列积压）
- [ ] **A7** LiteLLM gateway、backstage 等其余 apps —— 逐个评估，大部分 B2 探测即可

## 8. 日志（P2）

当前只收 pod 日志；宿主机 journald 一概没有。

- [ ] **G1** 部署 `logs/vlogs-ingress.yaml`（README 里一直挂着未做）
- [ ] **G2** 笔记本 journald → VictoriaLogs（openvpn、libvirt、k3s 本体）
- [ ] **G3** PVE 节点 journald（corosync / HA / fencing 事件）
- [ ] **G4** dc1 / bao1 日志
- [ ] **G5** VyOS syslog
- [ ] **G6** 基于日志的告警（vmalert + VictoriaLogs）——至少覆盖 fencing、OOM、openvpn 断线

## 9. 备份与周期任务（P2）

已有：共享 PG 备份、OpenBao snapshot、shared-data 证书/续期。

- [ ] **R1** Gitea 备份新鲜度
- [ ] **R2** ZFS 快照 / 复制新鲜度
- [ ] **R3** 其余 CronJob / systemd timer 的"最后成功时间"统一告警（`node_systemd_timer_last_trigger_seconds` 已有数据）
- [ ] **R4** 盘点：还有哪些数据没有备份（这本身不是监控，但监控会暴露出来）
  - ⚠ **PVE 上 9 个客户机全部没有备份**（`pve_not_backed_up_total` = 9，2026-10-05）。未设告警，留给备份梳理
  - ⚠ **dc1 没有任何备份**（2026-10-05）：唯一的 DC，磁盘是 zvol `data/vm/dc1`，无 ZFS 快照、无
    `samba-tool domain backup`、无 libvirt 快照。samba-ad README 写着"在域成为承重之前做"，现在已经是 SSO 底座

## 10. 收尾（P3）

- [ ] **Z1** 每个告警配 runbook 链接（`annotations.runbook_url`）
- [ ] **Z2** Grafana 总览看板：每台主机/每个入口一个红绿格
- [x] **Z3** `grafana-oidc` Secret 纳入 OpenBao/ESO（改为 iam-login 客户端 `grafana-sso`，由 Terraform 写入 bao）
- [ ] **Z4** 定期复查本清单（新服务上线时，把"加探测+告警"列入上线检查项）
