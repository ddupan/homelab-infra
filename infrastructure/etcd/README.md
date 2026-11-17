# Homelab shared etcd

独立于 PostgreSQL 与 k3s 的三成员协调服务。三个成员都由 Cinc（homelab-cookbooks 的
`homelab_data::etcd`，policy 在 `infrastructure/chef/policies/etcd-pve*.rb`）安装、配置并在本机续签证书；
Ansible 管 LXC、etcd 账号与成员增删；独立 Terraform root 管现有 Bao PKI 下的签发角色与 policy，
不管理 CA 或秘密值。
旧 Ansible Vault 不在本次迁移范围。

状态：2026-09-25 已部署三成员 etcd，启用 Bao mTLS 和 RBAC；三个端点健康检查通过。
PVE 两个 LXC 的 rootfs 已通过 `pct move-volume` 从 local-lvm 迁入 `pve-rg` SSD DRBD 池，
保留容器与 etcd 数据。当前 PVE LXC 迁卷要求停止容器，维护入口按成员串行执行，回归健康后再处理下一个。

| 成员 | 承载 | 地址 | 资源 |
| --- | --- | --- | --- |
| etcd-pve1 | pve1 新无特权 LXC 150 | 10.60.0.20 | 1 core / 1536 MiB / 8 GiB SSD DRBD |
| etcd-pve2 | pve2 新无特权 LXC 151 | 10.60.0.21 | 1 core / 768 MiB / 8 GiB SSD DRBD |
| etcd-pve3 | pve3 LXC 152 | 10.60.0.22 | 取代 etcd-laptop（#570） |

资源限额是初始测试预算，不是已测容量。LXC 已增加 PG standby/备份的独立 HDD mp0 与内存上限，生产 PG standby 与备份仓库已启动。
etcd 自身的 MemoryHigh/MemoryMax 仍为 256/384 MiB。labnet 依赖现有 VyOS 路由；切换 bare-metal 时复用服务角色，更换主机 inventory。

## 接入方式与认证

客户端使用三个 `https://地址:2379` endpoint，校验 Bao 中央 CA，出示独立客户端证书。
成员间 2380 也开启 mTLS，额外限制 peer CN 为 `homelab-etcd-peer`。
管理员证书 CN 为 `root`，只保存在受管成员 root 可读的文件中；对应 etcd root 用户不设置密码。
服务进程只能读取自己的 server/peer 私钥，不能读取管理员私钥。

Patroni 走 etcd3 gateway，使用无 CN 的客户端证书及独立 username/password 完成 RBAC。
实测带 CN 的证书会被 gateway 拒绝；管理员 CN=root 证书仅用于原生 etcdctl。
成员另有无 CN 的 gateway 证书供内部 gateway→gRPC 连接及密码核对使用，不能将管理员证书复用到 HTTP API。首个消费者为
`patroni-pg-prod`，只允许 `/homelab/patroni/pg-prod/`。其 Bao KV v2 路径为
`kv/infra/etcd/consumers/patroni-pg-prod`，包含 username/password/prefix；不在本文复制实际值。
配置 Patroni 时对应 `namespace: /homelab/patroni/` 与 `scope: pg-prod`。
第二个消费者 `patroni-pg-sandbox`（sandbox K3s datastore 的 Patroni，`scope: pg-sandbox`），
只允许 `/homelab/patroni/pg-sandbox/`；它的部署与续签身份 `homelab-sandbox-postgresql` 见
`terraform/sandbox.tf` 与 `../sandbox-cluster/README.md`。

第一次接入应由管理流程交付 CA、客户端证书及秘密引用，然后使用自己的身份对自己的 prefix
执行一次 put/get/delete。跨 prefix 应被拒绝；不要把 root 证书复制给应用。
生产消费者证书已签发，Patroni 已接入并验证主从自动切换。

## 安装与维护入口

成员的安装、配置、证书和快照都由 Cinc（`homelab_data::etcd`）负责，etcd 版本也在 cookbook 里固定
（Renovate 跟踪；升级要逐个成员重启）。这里只剩 Terraform（Bao PKI 角色、成员 SPIFFE 登录角色、
consumer policy）和几个 Ansible 运维入口，都不装软件、不需要额外 collection：

| playbook | 作用 |
|---|---|
| `lxc.yml` | 在 PVE 上创建成员 LXC 并登记 `etcd-pveN.lab.ddupan.top`；只创建不存在的 VMID |
| `member-join.yml` / `member-remove.yml` | 成员增删（见下文） |
| `bootstrap-auth.yml` | 一次性启用认证（`-e etcd_bootstrap_auth=true`）；已启用时不重建 |
| `consumers.yml` | 收敛消费者账号与 prefix，密码存 Bao |
| `verify.yml` | 用管理员证书检查全部端点 |

账号相关入口在第一个成员（`etcd[0]`）上用它本机的 admin 证书执行，控制端不持有 etcd 凭据；
需要 `BAO_TOKEN`（laptop 上 SPIFFE `local-development` 登录即可），token 不下发目标机。

```bash
cd infrastructure/etcd/ansible
ansible-playbook verify.yml
BAO_TOKEN=... ansible-playbook consumers.yml --check
BAO_TOKEN=... ansible-playbook consumers.yml
```

Terraform root 在 CI 的 `TF_ROOTS` 里，合并即 apply；state 在现有 S3 tfstate bucket，独立 key
`etcd/terraform.tfstate`，启用原生 lockfile。本地可从仓库根目录运行
`python3 infrastructure/etcd/run.py terraform <子命令>` 或 `python3 infrastructure/etcd/run.py ansible <playbook.yml>`，
复用当前 Bao 会话并在内存中取得所需凭据。
`lxc.yml` 不接管已有未知 VMID，也不自动调整运行中容器的网络与容量；配置漂移会报错。它登记的 lab 名是
IPAM 看到这些地址的唯一途径，见 `infrastructure/dns/README.md`。数据库角色不会创建/删除这些 LXC 或 etcd 成员。
首次认证启用前应限制客户端网络，不能把“已有中央 CA 签名”当作业务授权。

`consumers.yml` 首次生成 48 字符随机密码并以 KV v2 CAS=0 写入，之后只复用。
元数据存在但数据被删除、Bao 403/超时、或 etcd 用户存在但秘密丢失时均失败，不自动换密码。
并发 CAS 冲突会中止此次执行，重跑读取胜出的版本。既有额外角色或不同 prefix 权限也报错，
不默默扩大权限。账号删除、prefix 迁移和密码轮换均不包含在普通收敛里。
密码使用 stdin 送给 etcdctl，涉及秘密的任务 `no_log: true`；禁止用 `--diff` 打印未来消费者秘密文件。

证书有效期 60 天，剩余不足 14 天时续签。**每个成员自己续签**（2026-11-17 起三个成员都是）：
`homelab_data::etcd` 装的 `homelab-etcd-cert.timer` 每天运行 `/usr/local/sbin/homelab-etcd-cert`，
用节点的 SPIFFE 身份 `spiffe://ddupan.top/node/<成员>/etcd` 登录 Bao `jwt-spire` 角色
`homelab-etcd-member`（`terraform/member.tf`），只能签四类成员证书。私钥不离开节点，复用现有私钥，
原子替换；etcd 每个新连接都重新读取证书，**续签不需要重启**。手动触发：
`systemctl start homelab-etcd-cert`，再用 `openssl x509 -enddate` 和 `endpoint health` 核对。

Cinc 不重启 etcd：etcd.yml、unit 或二进制变化后 `homelab_data_restart_pending` 为 1
（`SharedDataRestartPending`），逐个成员手动重启，每次确认全部端点健康、raft 追平后再下一个。

原来的 laptop 续签控制端随 etcd-laptop 退出停用（etcd-pve1/2 的证书因此一度无人续签，直到 #791
迁入 Cinc），它和 Ansible 的安装 role（`site.yml`、`shared_etcd`）已从仓库删除。
成员启动本身仅用本地证书，不实时依赖 Bao。

## 备份与故障处理

每个成员有每日一次的 `homelab-etcd-snapshot.timer`，快照保存在各自
`/var/backups/homelab-etcd`，root-only，保留最近 3 个成功快照；snapshot status 验证成功才淘汰旧快照。
首备可执行 `systemctl start homelab-etcd-snapshot.service`，用 journal 和 `etcdutl snapshot status`
检查，不根据文件名推断备份成功。三处本地快照不等于异地备份。

quota 初始 256 MiB，按 1 小时保留进行自动 compaction；defrag 另择维护窗口逐成员做，
不能三个成员同时执行。metrics 绑定 loopback 与成员内网地址的 2381 端口，独立 listener 不提供 KV API；
与既有 LAN exporter 一样通过内网 HTTP 采集，禁止将端口映射到公网。
现有 VictoriaMetrics 使用 `platform/observability/metrics/scrapes/shared-etcd.yaml` 采集，
对应 VMRule 覆盖成员不可采集、少于两个可采集成员、无 leader、容量、WAL fsync 和频繁选举。
采集失败不等于 quorum 丢失，需结合管理员 endpoint health 判断。
备份年龄、证书到期与续签检查的主机采集已于 2026-09-27 部署，
告警规则已随 [PR #166](https://git.ddupan.top/panxiao81/homelab-infra/pulls/166) 合并并由 Flux 接管；
部署、阈值和排障见 [维护监控](../shared-data-monitoring/README.md)。既有 Alertmanager 已接入 Telegram，
维护者已收到本次成员无 leader 与频繁选举通知；接收器配置由现有监控栈维护。

### DRBD I/O 故障导致成员根卷只读

`SharedEtcdNoLeader` 是单成员指标，不等于全体没有 leader。先检查三个 endpoint，
并检查宿主机内核的 DRBD quorum、PingAck、I/O error 和 ext4 journal 日志。
`findmnt` 显示 `rw,emergency_ro` 仍表示文件系统已因错误停止写入；DRBD 恢复 quorum 不会自动修复它。

2026-09-25 17:16 UTC 起，CT150 根卷发生 quorum 短暂丢失、journal I/O 错误和 emergency_ro，
另外两个 etcd 成员保持健康。期间两个新 HDD 数据卷初始同步伴随多个 DRBD 资源 PingAck 超时。
只对本项目两个新数据卷设置 `DrbdOptions/PeerDevice/c-max-rate=10240`（10 MiB/s），
入口为 `../shared-postgresql/ansible/limit-resync.yml`，创建卷流程也复用该任务。
限速后短期未见新增超时，尚不构成唯一根因证明；未调整全局协议、quorum 或超时。

恢复顺序：确认另外两个成员健康并保存快照，正常停止故障容器，确认根卷卸载、DRBD quorum
和副本 UpToDate，再执行 `pct fsck 150 --device rootfs --force 1`。fsck 返回 1 表示已修复，
PVE 包装命令仍会报非零；需再次检查返回 0 才启动容器。不能在已挂载卷上执行 fsck，不能直接强制 remount。
本次修复后 CT150 启动，三个 endpoint 健康且 Raft term/index 一致；两个容器根卷与 mp0 均可写。
频繁选举告警含 15 分钟历史窗口，应核对最新计数和健康状态，不通过关闭规则消除通知。

- 单成员故障：先确认其他两成员仍健康，修复原成员；普通部署不删数据目录。
- 成员永久丢失：需单独执行 member remove/add 流程并同步 inventory，不用重新 init 覆盖。
- 全集群丢失：先恢复 Bao/信任根与恢复凭据，隔离全部旧成员，用同一有效快照恢复新逻辑集群。
  开放客户端前逐个协调消费者状态。Patroni 必须核对真实主库、timeline、lease/DCS 状态；
  不因旧快照宣称某节点为主就允许它写入。完整跨服务灾难恢复演练尚未完成。

### 加入 Cinc 管理的新成员（etcd-pve3 取代 etcd-laptop，#570）

Cinc（`homelab_data::etcd`）装好成员并用节点自己的 SPIFFE 身份签好证书，但 unit 在
`member add` 之前不启动：没有数据目录、也没有 `/etc/homelab-etcd/join` 时 systemd 条件不满足。
成员写进 inventory 的 `etcd_cinc` 组，首次收敛后运行：

```bash
cd infrastructure/etcd/ansible
ansible-playbook member-join.yml --check -l etcd-pve3   # 只读：发现成员、检查健康
ansible-playbook member-join.yml -l etcd-pve3
```

它在新成员上用其自己的 admin 证书（CN=root）以 **learner** 登记、放 join 标记并启动、追上后
promote、移除标记、确认全部成员健康，没有快照时做首个快照。learner 不计入 quorum：直接加入会让
3 成员（quorum 2）变成 4 成员（quorum 3），新成员起不来时再掉一个就丢 quorum，Patroni 随即降级
pg-prod 主库。已加入的成员重跑只做检查（`changed=0`）；不在集群里却带着旧数据目录的节点会被拒绝，
清不清空由人判断。

### 移除成员

先把消费者配置（Patroni 的 `etcd3.hosts`）改掉并写到节点上，再运行：

```bash
cd infrastructure/etcd/ansible
ansible-playbook member-remove.yml --check -e etcd_remove_member=etcd-laptop
ansible-playbook member-remove.yml -e etcd_remove_member=etcd-laptop
```

它在存活的 Cinc 成员上确认移除后仍有至少 3 个健康的投票成员，`member remove`，再停用被移除节点上的
etcd 和定时任务（目标本身可以已经坏了，第二个 play 不可达时移除已完成，重跑或手动收尾即可）。数据目录保留。

etcd-laptop 移除时 `homelab-etcd-renew.timer` 一并停用。etcd-pve1/2 于 2026-11-17 迁入 Cinc（#791，
#570 第 4 步）：recipe 路径与原 Ansible role 相同，原地接管，随后逐个重启以应用新的 etcd.yml。

## 验证

```bash
cd terraform && terraform validate
cd ../ansible && ansible-playbook --syntax-check verify.yml consumers.yml member-join.yml
ansible-playbook verify.yml
```

成员本身的测试在 homelab-cookbooks 的 `homelab_data`（ChefSpec + Kitchen）。原来对 Ansible 模板的
loopback 三成员集成测试随 role 一起删除；下面 2026-09-25 的记录是当时的结果。

源码边界与 PostgreSQL 后续设计见 [研究记录](../shared-postgresql/RESEARCH.md)。

2026-09-25 验证结果：Terraform validate 通过；Ansible lint 零文件级问题；隔离三成员测试通过，
认证初始化与消费者第二次执行均 `changed=0`，包含 gateway 写入、密码漂移拒绝、快照离线恢复、
停止一成员后继续写入。测试低负载 RSS 约 36.6–40.4 MiB/成员，仅作开销参考。
现场验证：Bao PKI roles/policies 已应用，三成员已签发证书并启动；认证初始化与
`patroni-pg-prod` 账号创建成功，随机密码已保存 Bao，实际 gateway 登录验证通过。
两台 LXC 的 rootfs 均为 `pve-rg`，运行状态正常；迁移后全部端点成功提交健康探测。
现有监控已接入；自动续签已启用；备份/证书年龄告警于 2026-09-27 补齐并启用。PostgreSQL 部署状态见其 README。

监控接入验收（2026-09-25）：三个 `up{job="shared-etcd"}` 均为 1，六条规则 health=ok，
三端点健康检查通过。新增续签调度四项失败/成功路径测试通过，Terraform validate 与 Ansible lint 通过，
隔离三成员测试再次通过。[IaC PR #159](https://git.ddupan.top/panxiao81/homelab-infra/pulls/159) 已合并。
2026-09-25 合并后核实：Flux observability Ready，应用版本 `f6d12d6`，
etcd/PG 的两份 VMRule 与两份 VMStaticScrape 均已纳入 inventory，状态 operational；
三个 etcd 与两个 Patroni 抓取目标均 up=1，相关 11 条告警 health=ok、inactive。备份/证书年龄告警不包含在这六条规则中。
