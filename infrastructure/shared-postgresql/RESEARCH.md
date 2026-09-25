# Shared PostgreSQL：Pigsty 裁剪研究

日期：2026-09-25。状态：源码研究与方案建议，尚未部署、压测或决定迁移。维护者已确定 etcd 按全 homelab 共享基础设施设计，其余实现细节仍为建议。

研究基线：Pigsty `v4.5.0`，commit `dab5dba333a070d96fde1f9feb41761148f2be8c`，浅克隆位于 `/tmp/pigsty-source-review`。下文相对源码路径均指此版本。保留上游 Apache-2.0 许可及适用的版权声明。

## 结论

可以裁剪，优先保留 PostgreSQL + Patroni + etcd + pgBackRest，复用 pg_exporter 和经过筛选的规则。无需带入仓库服务器、PgBouncer、Supabase、Grafana/VictoriaMetrics 全栈、门户和 MinIO。

但这不是一份关闭功能开关的 inventory 就能完成的工作。主要改造点是：实例与宿主机解耦、移除对宿主机的全局接管、重做初始化权限、补齐可验证的备份和切换流程。建议维护独立的精简 Ansible 实现，明确记录取自上游的文件和基线；不保留无用组件及其配置兼容负担。

现阶段没有实测 RSS、HDD fsync 延迟和故障恢复时间，不能宣称任何 HA 方案已经满足资源预算。

## 已知需求与现状

- 数据库独立于 k3s；生产自动故障转移；开发不要求 HA。
- laptop ZFS SSD 为正常生产 primary 所在地；PVE HDD LXC 承担 standby。
- 开发与生产共用物理机器，但使用独立 PGDATA、端口、操作系统账号和资源约束。
- IaC 管宿主资源、实例、HA、备份、监控；Ayatori 管业务数据库、账号和凭据；Backstage 管门户。
- 异地备份暂缓，首期仍包含本地备份与恢复验证。
- 本会话先前只读检查：现有 CNPG 为 PostgreSQL 18.3，数据库合计约 185 MiB，PGDATA 约 748 MiB，其中 WAL 约 561 MiB；活跃 10 GiB PVC 的文件系统使用量约 795 MiB。这不是备份压缩后的体积，也不是新的持续监控结果。
- Gitea 数据库约 43 MiB、NetBox 约 29 MiB；NetBox 可能退役。Git 仓库、LFS、附件等不包含在数据库体积里。

## 源码发现与处理

| 范围 | 源码依据 | 结论与处理 |
| --- | --- | --- |
| 最小入口 | `slim.yml` | 已跳过 INFRA、监控栈和仓库服务，但仍执行 NODE、HAProxy、ETCD、PGSQL；不能直接当共享宿主部署入口。 |
| 生命周期 | `pgsql.yml`、`roles/pgsql/tasks/main.yml` | 初始化与日常收敛不是同一件事。拆成 provision/configure/upgrade/recover，禁止普通配置更新重跑 bootstrap。 |
| 同机多实例 | `roles/pgsql/tasks/install.yml`、`config.yml`；全仓检索 `pg_instances` | `pg_instances` 仅见注释/元数据，没有实例循环实现。硬编码 `/pg`、Patroni/PG service、pgBackRest/exporter 配置与全局环境文件；改端口或 inventory alias 不够。 |
| 宿主机接管 | `roles/pgsql/tasks/install.yml:58` 起、`roles/node/tasks/main.yml` | Debian 清理逻辑会停止默认 PG、删除发行版 systemd unit，包含立即停库与 kill 回退；NODE 管 DNS、软件源、调优等。删除这些逻辑，仅管理自己声明的资源。 |
| 包依赖 | `roles/node_id/vars/d12.aarch64.yml` 等发行版映射 | `pgsql-common` 仍包含 PgBouncer、vip-manager、backup exporter；`pgsql-main` 也含多种扩展/语言包。关闭服务不等于减少安装，必须改为明确的包清单并固定版本策略。 |
| 调优 | `roles/node_id/tasks/main.yml`、`roles/pgsql/templates/tiny.yml:14` 起 | `tiny` 默认仍为 250 connections，内存按宿主计算，work_mem 下限 16 MiB。共享 laptop/LXC 应按实例预算计算，不能把整机资源分配给每个实例。 |
| HA 替换 | `roles/pgsql/tasks/main.yml`、Patroni 模板与恢复脚本 | 禁用 Patroni 并不会得到另一套完整的初始化/HA 实现；换 pg_auto_failover 是重新接生命周期和恢复流程，不能按少一个组件直接判定更便宜。 |
| 路由 | `roles/pgsql/templates/service.cfg` | 已有 Patroni HTTP 角色检查、PostgreSQL 直连目标与摘除旧会话的逻辑，可抽取接既有 HAProxy。自动选主必须同时解决稳定入口与客户端重连。 |
| 初始化权限 | `roles/pgsql/tasks/patroni.yml:103` 起、`pg-init-roles.sql`、`pg-init-template.sql` | `pg_provision: false` 只跳过业务 provisioning，不跳过 bootstrap SQL。默认角色和 template1 修改仍会发生；替换为最小初始化，不能直接给 Ayatori 默认 superuser DBA。 |
| 备份 | `roles/pgsql/tasks/pgbackrest.yml`、`roles/pgsql/templates/pgbackrest.conf` | stanza/首备错误被忽略；全局 initial.done；模板仅渲染 repo1；按整机 CPU 计算并行度。需要实例化路径、明确失败门禁、保守并行度。 |
| 调度 | `roles/pgsql/defaults/main.yml:25`、`files/postgres/pg-backup` | 默认 pg_crontab 为空；备份脚本虽然检查 primary，但硬编码 `/pg` 与默认配置。部署成功不代表周期备份存在。 |
| 监控接入 | `roles/pg_monitor/tasks/register_victoria.yml` 等 | 上游注册到自己的 infra 目录。只取 exporter 部分，改为本仓现有 VMStaticScrape/VMRule 接入方式，不部署新的监控服务。 |

上游固定版本入口：[slim.yml](https://github.com/pgsty/pigsty/blob/dab5dba333a070d96fde1f9feb41761148f2be8c/slim.yml)、[pgsql tasks](https://github.com/pgsty/pigsty/tree/dab5dba333a070d96fde1f9feb41761148f2be8c/roles/pgsql/tasks)、[监控规则](https://github.com/pgsty/pigsty/blob/dab5dba333a070d96fde1f9feb41761148f2be8c/files/victoria/rules/pgsql.yml)。

## 建议拓扑

| 故障域 | 首期部署 |
| --- | --- |
| laptop | prod primary + Patroni；dev 单实例；etcd 成员 A；exporter。prod/dev 分别使用 ZFS dataset。 |
| PVE 主机 A 的 LXC | prod standby + Patroni；etcd 成员 B；exporter。 |
| PVE 主机 B 的 LXC | etcd 成员 C；本地 pgBackRest 仓库可与此共置，不额外引入对象存储服务。 |
| 既有入口 | HAProxy 按 Patroni `/primary` 健康检查转发生产写连接，开发使用独立入口。 |
| 既有监控 | vmagent 抓取；现有 vmalert/Alertmanager 评估与发送告警。 |

首期只配一个 PG standby；第二个 PVE LXC 可以只承担投票成员和备份仓库。两个 PVE LXC 必须跨实际物理主机，否则不能算两个故障域。etcd 不复用 k3s 的 DCS。

## Shared etcd 的管理边界

维护者于本轮明确：etcd 做成全 homelab 共享服务。原方案将 etcd 列入数据库部署角色；调整后 etcd 拥有独立的 inventory、部署入口、升级、快照和恢复流程，PostgreSQL 是第一个消费者。建议代码归属 `infrastructure/etcd/`，数据库只声明端点、客户端凭据和自身的 DCS prefix。物理共置方式可沿用上表，不因此增加节点。

- 为每个消费者分配独立账号与 key prefix，并用 etcd RBAC 约束读写范围。Patroni 示例：`namespace: /homelab/patroni/`、`scope: pg-prod`，只授权 `/homelab/patroni/pg-prod/`。路径命名本身不是权限隔离。参考 [etcd RBAC](https://etcd.io/docs/v3.6/op-guide/authentication/rbac/)。
- 客户端配置三个直接可达的 TLS endpoints；etcd 维护不依赖生产 PostgreSQL、Ayatori 或 k3s 的可用性。etcd root 仅用于基础设施管理，不交给消费者。
- 维护者明确 mTLS 证书使用 OpenBao 中央 CA 签发，删除 Pigsty 自建 CA 的部署依赖。建议分别定义 etcd server、peer、consumer 签发角色，限制名称、SAN、用途和签发权限；peer 需要 serverAuth/clientAuth，消费者凭据按服务独立。中央 CA 签名本身不等于获准加入 peer 网络，必须限制 peer 身份及网络入口，必要时使用中央 CA 下的专用中间 CA。证书私钥在目标机生成并以 CSR 签发；IaC 管角色和续签流程，秘密不进入 Git/state。
- 已签发证书与信任链保存在本地，etcd 正常启动不要求即时连接 Bao；提前续签、校验证书并按成员轮换，告警覆盖过期风险。Bao 不迁入此 etcd，也不依赖 PostgreSQL；灾难恢复沿用先恢复信任根的边界。Bao 暂时不可用时，现存有效证书仍可完成 TLS 验证。
- Patroni etcd3 使用 gRPC gateway，不能依赖客户端证书 CN 映射来完成 RBAC 身份认证；隔离实测还要求 gateway 客户端证书省略 CN；配置独立 username/password，并保留 TLS 校验。凭据由现有秘密管理提供。Pigsty tiny 模板已包含 username/password，但默认密码可退化为集群名，必须替换。参考 [Patroni etcd 配置](https://patroni.readthedocs.io/en/latest/ENVIRONMENT.html#etcd)。
- 维护者确定 Patroni etcd 密码随机生成并存入 Bao。实施时首次创建使用 KV v2 CAS 防止覆盖已有值，之后收敛复用同一 secret；读取失败不能当成不存在而重置密码。显式轮换需同步 etcd 账号与 Patroni 配置。Ansible 在执行时读取、以 no_log 和受限文件权限下发，不新增 Ansible Vault 副本。共享 etcd 实施阶段已生成并写入该线上 secret，gateway 登录验证通过；Patroni 尚未部署。
- 仓库配置检查显示 Ansible Vault 尚未整体退出：OpenBao、Samba AD、Proxmox 的 ansible.cfg 仍引用根目录 `.vault_pass`；OpenBao/Samba AD 仍有 vault.yml 路径，OpenBao README 仍将 OIDC client secret 归入该文件。未解密这些文件，也未查询 Bao 中是否存在对应副本。既有秘密迁移另行盘点；Bao 自身 bootstrap/恢复材料须保留独立恢复途径，不能只存在需要它们才能恢复的 Bao 中。
- 共享的是小规模配置、服务协调和选主能力。key 权限不隔离磁盘、写入负载、compaction 或集群故障；新增消费者须控制写入量、value 大小与历史保留，监控全局容量和延迟。暂不迁移 k3s 的内部 datastore。
- 快照、compaction、defrag 和成员维护统一由共享 etcd IaC 管理。卸载 PostgreSQL只清理其授权范围内的资源，不删除 etcd 成员或恢复整个集群。
- etcd 全集群恢复会回退所有消费者状态，不能拿整集群 snapshot 当单个应用的回滚。恢复 runbook 要协调 Patroni 的实际数据库角色、lease 与 DCS 状态，并为其他消费者保留恢复步骤。

这项决策进一步支持保留 Patroni：etcd 的运行与维护成本由多个使用者共享，无需为每个数据库集群再建一套 DCS。

PVE 改为 bare-metal 目前只是维护者表达的后续倾向，不构成本轮迁移决定。etcd/PG 角色面向普通 Linux systemd 主机，LXC 创建及宿主资源配置单独管理，以便未来更换承载方式时复用。

三个 etcd 成员不是三个额外的大 VM，可与上述角色共置。etcd 数据很小，但对磁盘延迟敏感；必须观察 PVE HDD 在备份/数据库负载下的 fsync 和选举稳定性，低数据量不自动代表低延迟。

开发默认不使用 Patroni/etcd，不做 standby，进一步减少常驻资源。若另建 laptop 容器，能保留更多上游单机单实例代码，但会引入容器生命周期、网络和挂载管理；因此首选直接实例化 systemd service，容器为已有成熟运行时可复用时的备选。

生产 PG、Patroni 和 exporter 数量分别为 2、2、2；开发再加一个 PG 和 exporter；etcd 共 3 个成员。pgBackRest 可通过 timer/SSH 工作，不必常驻对象存储服务器。这是角色数量，不是 RSS 估算。

## 自动切换的边界

建议先采用异步复制，使常态 SSD 写延迟不被 HDD 提交路径限制。故障切换可能丢失尚未复制的已提交事务。`maximum_lag_on_failover` 是候选资格阈值，不能宣传成精确 RPO；官方还计入最近 TTL 窗口的 WAL。见 [Patroni replication modes](https://patroni.readthedocs.io/en/latest/replication_modes.html)。

自动化包含：故障检测、候选提升、入口切换、旧主恢复后 rewind/rejoin。不自动抢回 laptop 主角色，避免反复抖动；正常时优先让 laptop 承担 primary，故障后先稳定运行于 HDD。是否需要 laptop 恢复后经过稳定窗口自动回切，须另定义策略，不能用循环抢主代替。

必须区分“进程死亡”和“进程暂停/内核卡死”。上游 watchdog 默认 off，DCS 多数派本身不构成对卡死旧主的物理隔离。LXC 不应随意透传宿主 `/dev/watchdog`，否则可能重启整台 PVE。首期可评估软件降级与入口隔离的 best-effort 边界，但不能宣称所有故障下零双主；暂停 Patroni、网络单向中断和旧连接的行为必须进入演练。必要时再增加受控的宿主级 fencing，而不是先部署一套重型编排。见 [Patroni watchdog](https://patroni.readthedocs.io/en/latest/watchdog.html)。

上游 tiny 开启 DCS failsafe：现有 primary 在满足与所有已知 PG 成员通信等条件时可继续服务，但没有 DCS quorum 不能把它当作通用选主替代。见 [DCS failsafe](https://patroni.readthedocs.io/en/latest/dcs_failsafe_mode.html)。

既有 VyOS/HAProxy 仍是端到端可用性的依赖；复用它不等于数据库入口已经消除单点。要验证现有 VyOS 故障恢复及角色感知检查，不能沿用只检查 TCP 可连接的逻辑。

## 备份首期设计

- pgBackRest 备份仓库放在 laptop 之外的 PVE HDD，使用普通文件系统仓库与 SSH/TLS 访问，不需要 MinIO。两台生产 PG 都能归档到同一 stanza/repository。
- 以每日 full、保留最近 3 个成功 full 及恢复所需 WAL 为初始本地策略；这不等于严格覆盖任意时刻之前 72 小时。若要求完整 72 小时窗口，应增加锚点备份及相应 WAL。异地策略另行决定。
- 周期任务跟随实际 primary 或由仓库端发现 primary；切换之后必须继续备份，不能把 inventory 中初始 primary 当作永久主库。
- 备份并行度先从 1 开始，设置任务超时、磁盘配额与成功时间告警；初始备份失败即判部署验收失败。
- 连续 WAL 归档也应明确 `archive_timeout`，低写入量下不能把“配置 archive_command”当作 WAL 已及时落到仓库。初始候选为 5 分钟，结合生成量与恢复目标实测调整。
- 上游固定 `archive-push-queue-max=4GiB`。超过限制时 pgBackRest 可丢弃归档并破坏该区间 PITR，不能照抄后声称持续可恢复；先明确可用性与保留 WAL 的取舍，并补积压、归档失败和磁盘告警。见 [pgBackRest 配置](https://pgbackrest.org/configuration.html#section-archive/option-archive-push-queue-max)。
- 备份文件存在不算验收：隔离恢复到指定时间点并执行一致性检查；避免恢复出来的开发实例向生产仓库归档。

## exporter 与规则：可以裁得很小

对固定版本 `files/victoria/rules/pgsql.yml` 做 YAML 解析：共 **402 条 recording rules、16 条 alerts**。排除 4 条 PgBouncer alerts 和依赖整机综合压力的 `PostgresPressureHigh`，剩余 **11 条 alerts 仅依赖 8 条 recording rules**（按表达式中的 recording metric 递归追踪）。没有必要搬完整 402 条。

需要保留的 recording metrics：`pg:cls:partition`、`pg:db:age`、`pg:db:conn_limit`、`pg:db:conn_usage`、`pg:db:ixact_backends`、`pg:db:num_backends`、`pg:ins:lag_bytes`、`pg:ins:lag_seconds`。这只是依赖分析，不代表这些告警已通过运行验证。

仍需修正：

- 使用 Pigsty 的 `pg_exporter` 指标体系，不能直接替换为另一款 `postgres_exporter` 而照搬规则。
- 保持或显式转换 `cls/ins/ip/job`；同 IP 多实例按实例端口和标签识别，禁止把宿主 CPU/内存用量重复算成每个数据库的用量。
- `pg:cls:partition = count(... == 0)` 在没有 primary 时可能返回空向量，后续 `!= 1` 不足以保证无主告警；增加预期集群基线/缺失检测。
- exporter 完全不可抓取时不能指望 exporter 自己的 `*_up` 指标告警；增加 scrape `up == 0` 与 target 消失检查。
- `PostgresReplicationBreak` 用 streaming 数量的变化检测，不能覆盖所有持续缺副本情况；补预期 replica 数与持续复制失败。
- severity 从上游 `CRIT/WARN/INFO` 映射为既有路由使用的 `critical/warning/info`，去掉指向未部署 Pigsty UI 的链接。
- 从 collector 白名单开始，避免默认启用所有逐库/逐查询采集。一些 collector 依赖 `monitor` schema/辅助函数；删 bootstrap SQL 时要一起裁 collector。监控辅助 SECURITY DEFINER 与 Ayatori 管理 API 是不同权限问题，不为兼容 exporter 保留整套 DBA 权限。
- 补本地备份年龄、WAL 归档失败/积压、磁盘余量、etcd quorum/延迟，以及数据库端到端读写探测。

## Ayatori 与 IaC 的边界

IaC 仅建立实例运维必需的账号、复制账号、最小监控权限和 Ayatori 管理账号；业务数据库及 owner 不再同时放入 Pigsty `pg_users/pg_databases`。

Ayatori 使用既定的非 superuser `CREATEDB/CREATEROLE` 管理账号，按现有契约验证 PostgreSQL 18 的角色成员关系与所有权操作。应用凭据走 OpenBao/ESO，不进入 inventory 明文、日志或 CR。凭据发放、轮换和删除能力是否已可用要以 Ayatori 当前实现验收，不能把 Instance 注册成功当作 provisioning 已完成。

Backstage 不属于本裁剪仓库。PG/etcd/systemd 的创建与恢复也不塞进 Ayatori。

## 推荐实现切分与验收

1. 建立最小 inventory 模型，区分 host 与 instance；声明 prod/dev 的 uid、dataset、端口、socket、配置路径、systemd slice 和预算。所有控制文件、锁文件、日志及 pgBackRest spool 都实例化。
2. 独立实现 shared etcd 的部署与消费者账号管理，再提取数据库 package、instance、Patroni、backup、exporter 角色；移除 upstream NODE 全局操作。初始化有前置条件，空目录才能 init，变更部署与恢复入口分开。
3. 先在隔离环境验证同宿主 prod/dev：重复执行不重新初始化、不重启无关实例、不改变全局 PG unit、DNS 或调优；资源统计使用 cgroup/RSS/PSS，不能把 PostgreSQL 各进程共享内存重复求和。
4. 加入两数据节点与三投票成员，验证 primary 故障、任一 etcd 故障、网络分区、进程暂停、旧主回归、入口旧连接回收和客户端重试；记录实际 RTO 与丢失事务。
5. 触发主库切换后再次备份，并从备份恢复；模拟仓库不可达、任务失败、WAL 积压，验证报警及恢复链边界。
6. 连接现有监控与 Ayatori，验证 create/rotate/retain/delete 契约，再安排 CNPG 分应用迁移。Gitea 迁移同时协调应用停写与其非数据库存储，但不将其文件迁移混入本次 DB 基础设施研究。

pg_auto_failover 保留为候选，其官方主分支安装文档声明支持 PG 13–18，但依赖带 PG 的 monitor；是否更省资源需要在同预算、同故障场景下测量。当前不建议为了组件名字少一点而舍弃已经能提取的 Patroni 配置、路由与恢复经验。见 [官方安装文档](https://github.com/hapostgres/pg_auto_failover/blob/main/docs/install.rst)。

本研究阶段未修改现有数据库；后续 shared etcd 已以独立 IaC 部署，详见下方实现状态。设计边界已同步到 homelab-wiki 的 `architecture/constraints.md` 与 `services/shared-postgresql.md`，文档直接发布到 main，IaC 通过独立 PR 发布；现有 CNPG 服务状态未发生变化。


## 实现入口

共享 etcd 的首轮实现与验证见 [etcd README](../etcd/README.md)，包括独立 Bao PKI/policy Terraform、
LXC 与成员 Ansible、消费者秘密与 RBAC、快照和隔离三成员测试。三成员已部署，PVE 两个 LXC 使用 `pve-rg` SSD DRBD；数据库 IaC 与隔离切换/恢复测试已具备，生产主从、开发实例、稳定入口和本地备份已上线，真实切换与隔离恢复通过；现有 CNPG 应用迁移未开始。具体状态见 [部署 README](README.md)。
旧 Ansible Vault 迁移按维护者要求后置，不阻塞新增消费者直接使用 Bao。

2026-09-25 后续只读前置核查：laptop 为 Ubuntu 24.04.4，ZFS `data` 池当时约 526 GiB 可用，
5432/5433/8008 未监听；CNPG 声明镜像为 `18.3-system-trixie`。新实例继续按 PG 18 主版本准备。
此核查没有创建 PG dataset、安装数据库或迁移应用；容量与端口使用可能随后改变，执行前须再核对。
