# k3s 外共享 PostgreSQL

面向 homelab 的 PG 18 + Patroni + pgBackRest，复用现有 Bao、shared etcd、VyOS 和监控栈。
开发与生产共用 laptop，但使用独立 OS 用户、数据集、端口与配置。没有部署 Pigsty 全栈。

**2026-09-25 已上线新生产主从、独立开发实例、稳定入口与本地备份。**
现有 CNPG 和应用数据未迁移。Ayatori 按维护者决定沿用独立控制面规划，本轮只备齐接入材料，
未向现有 k3s 部署 Ayatori 或 Instance CR，也不能宣称 Instance Ready。

## 入口与拓扑

| 承载 | 角色 | 数据目录/入口 | 初始预算 |
| --- | --- | --- | --- |
| laptop | prod 正常主库 / Patroni | `/var/lib/homelab-postgresql/prod`，192.168.10.127:5432 | ZFS quota 32 GiB；PG MemoryMax 1 GiB |
| pve1 LXC150 | prod standby，与 etcd 共置 | 同 prod 目录，10.60.0.20:5432 | HDD mp0 16 GiB；容器 1536 MiB |
| laptop | dev 独立实例 | `/var/lib/homelab-postgresql/dev`，pg-dev.ad.ddupan.top:5433 | ZFS quota 8 GiB；MemoryMax 384 MiB |
| pve2 LXC151 | pgBackRest 仓库，与 etcd 共置 | `/var/lib/homelab-pgbackrest` | HDD mp0 32 GiB；容器 768 MiB |
| VyOS | 生产稳定 TCP 入口 | pg-prod.ad.ddupan.top:5432 → 192.168.10.2:5432 | 独立 HAProxy service，MemoryMax 64 MiB |

两个 LXC 的 rootfs 保持 `pve-rg` SSD DRBD，数据盘为 `pve-rg-hdd`。
laptop ZFS 使用 recordsize=16K、lz4、atime=off。预算不是容量或 SLA 承诺，standby 的 16 GiB
小于主库 quota，扩容应以较小容量为约束。PG prod/dev 分别为 `pgprod`/`pgdev`，配置和 socket 隔离。
初始 prod shared_buffers=128 MiB / max_connections=80；dev 为 32 MiB / 30。
现场版本为 PostgreSQL 18.6、Patroni 4.1.5、pgBackRest 2.59.1。

客户端必须使用自己的业务凭据及 `sslmode=verify-full`。本轮仅建立 Ayatori 非 superuser
管理账号（CREATEDB/CREATEROLE），未交付普通应用账号。公开中央 CA 位于 `ca.crt`。
例如，在已获管理身份的受控终端用交互密码提示验证，不在命令行填写密码：

```bash
psql 'host=pg-prod.ad.ddupan.top hostaddr=192.168.10.2 port=5432 dbname=postgres user=ayatori sslmode=verify-full sslrootcert=ca.crt' -W
```

生产采用异步复制，自动切换可能损失未复制的已提交事务；最大候选落后阈值 1 MiB 不是精确 RPO。
Patroni REST 绑定内网 8008，写操作有独立认证。HAProxy 校验 `/primary`，摘除旧主时关闭旧会话；
角色变换与代理收敛期间可能出现短暂连接错误或只读响应，应用应使用适当重试。
没有硬件 watchdog/fencing，尚未验收进程冻结、网络分区或整站故障，不能把服务停止演练当作覆盖所有故障。

## IaC 与秘密

本目录 Terraform 独立 state 为 `shared-postgresql/terraform.tfstate`，使用现有 S3 `terraform`
身份；`run.py` 在内存读取 `kv/k8s/seaweedfs-s3` 的 AK/SK。首次 PKI/JWT role/policy 管理由有效
Bao 管理会话 plan/apply，业务部署改用受限 SPIFFE role `homelab-postgresql`。

```bash
python3 run.py terraform plan
PG_BAO_SPIFFE_ROLE=homelab-postgresql python3 run.py --spiffe ansible credentials.yml
```

`--spiffe` 从本机 Workload API 取得 JWT-SVID，交换短期 Bao token，执行后撤销；失败不回退到
旧 CLI token，不写 `~/.vault-token`。专用 role 绑定 `spiffe://ddupan.top/dev/panxiao81`，只允许
所需签发路径、实例 KV 与 Ayatori 交付路径，既有 etcd 消费者只读；没有 PKI/auth 管理或 KV 删除权限。
Terraform provider 直接使用包装器的 token（skip_child_token），不另外创建子 token。

原始实例秘密位于 `kv/infra/postgresql/{prod,dev}`；`initialize-secrets.yml` 仅在元数据明确不存在、
数据目录尚未初始化时 CAS=0 创建。403、软删除、密码缺失或漂移均不能触发隐式重置。
Ayatori 单独使用 `kv/infra/postgresql/ayatori/{prod,dev}`，仅有 username/password，由
`ayatori-credentials.yml` CAS 创建及回读核对。未来 ESO 只读这两个路径，不读取完整实例秘密。
涉及秘密的任务 no_log，禁止对凭据 play 使用 diff。旧 Ansible Vault 未迁移。

## 部署与维护入口

1. `storage.yml` / `pve-storage.yml` 准备专属卷和预算；`preflight.yml` 拒绝未知数据或错误挂载。
2. `packages.yml` 预装软件，阻止 apt 自动初始化默认 main；只刷新 Ubuntu 与本项目 PGDG 源，
   仍校验签名，不接管 laptop 无关第三方仓库故障。
3. Terraform 准备 PKI 与身份，`initialize-secrets.yml -e pg_allow_initialize=true` 首次创建密码。
4. `site.yml` 写入实例配置和证书；不初始化、不自动重启。`backup.yml` 建立专属仓库与 SSH 传输。
5. `bootstrap.yml -e pg_allow_initialize=true` 显式初始化空目录，先 laptop 后 standby；未知数据不接管。
6. `bootstrap-backup.yml` 验证 WAL 与首备成功后启用每日 timer；`proxy.yml` 要求唯一 primary 才发布入口。
7. DNS 由 `infrastructure/samba-ad/ansible/group_vars/all/dns.yml` 与 Samba `provision-dc.yml --tags dns` 管理。
8. `controller.yml` 安装 PG 证书每日续签调度，预检通过才启用。
9. `monitoring.yml` 激活 SQL 指标：先由 `site.yml` 写入模板，再执行本 play。它只在配置未生效时
   向 Patroni 发 HUP、对 pending 成员 `patronictl restart --pending`（primary 原位重启，不 failover，
   写入短暂中断）或重启 dev；随后在可写实例创建监控角色与扩展并安装 exporter。不需要 Bao。
10. Ayatori 已接入（Instance、管理凭据同步由 Ayatori 部署 role 与 `infrastructure/ayatori/ansible` 管理，
    数据库经 `clusters/ayatori-<env>/` 申请）；CNPG 迁移另行按应用验收。

普通 `site.yml` 不代表所有配置已在线激活；尚未实现通用参数变更的 rolling restart。
专用 `renew-certificates.yml` 只处理证书，60 天有效期、剩余不足 14 天续签；逐主机检查服务，
需要时签发并向 Patroni/PostgreSQL 主进程发送 HUP，最后检查 SQL。`homelab-postgresql-renew.timer`
每日 04:30 UTC 加随机延迟；日志由同名 service journal 查询。程序与 Ansible 副本位于
`/opt/homelab-postgresql-controller`，由 root 管理，以本机开发身份取短期 token。
续签依赖现有 SPIRE（在 k3s）和 Bao；数据库与 etcd 的正常运行仅用本地证书，不实时依赖 k3s。

### 连接池（PgBouncer）

应用默认连 **`pg-prod.ad.ddupan.top:6432`**（VyOS → 当前 primary 上的 PgBouncer → 本机 socket），
`sslmode=verify-full` 与租户凭据不变，只换端口。每个 prod 成员一个 `homelab-pgbouncer-prod`，
transaction 模式，每（库, 角色）对最多 `pg_pooler.default_pool_size` 条服务端连接（group_vars）。
账号不落文件：`auth_query` 经无密码的 `homelab_pooler`（peer + ident 映射）调用 SECURITY DEFINER
函数 `homelab_pooler.user_lookup` 取 SCRAM 秘密并透传登录，所以 Ayatori 新建的租户角色无需任何配置；
superuser 与复制角色查不到，只能直连。

**不走池、直连 5432 的：** 迁移与 `pg_dump`/`pg_restore`、Ayatori 管理连接、Patroni/备份/exporter，
以及依赖会话状态（LISTEN/NOTIFY、会话级 advisory lock、`SET` 不带 `LOCAL`）或长期占住连接的客户端
（backstage：events 用 LISTEN，knex 按插件各自建池）——这类改为收紧自身池大小。
transaction 模式下命名预编译语句可用（`max_prepared_statements` 默认 200）。

部署：`site.yml`（写入 HBA/ident）→ `pooler.yml` → `proxy.yml` → `controller.yml`（续签程序副本
带上池的重载）。`tests/pooler_integration.py` 用真实模板在临时容器中验证认证透传、拒绝 superuser/
复制角色、预编译语句与连接复用。告警：`SharedPostgresPoolerDown`（直接探两个成员的 `:6432`，
因为 HAProxy 只看 Patroni，不会摘掉坏掉的池）。

### 计划内切换主库（含 laptop 重启后回切）

laptop 重启、或停掉 `homelab-postgresql-prod` 时，Patroni 会自动把主库切到 pg-pve1（HDD），
15 分钟后触发 `SharedPostgresPrimaryOnStandbyHost`。在 laptop 上回切：

```bash
infrastructure/shared-postgresql/switchover.py          # 预检：唯一 Leader、候选 streaming、同一时间线、落后 ≤ 1 MiB
infrastructure/shared-postgresql/switchover.py --run    # 执行并等待候选成为 primary、其余成员恢复 streaming
```

生产写入会中断数秒（2026-09-25 演练约 9 秒），入口代理跟随 Patroni `/primary`，客户端无需改配置。
计划内维护 laptop 前也可先 `switchover.py --candidate pg-pve1 --run` 主动切走，避免非计划 failover。

## 备份与恢复

仓库主机发起备份，发现实际 primary；每天 03:40 UTC 加随机延迟执行 full，保留 3 个 full，
本地连续归档 WAL。WAL archive_timeout=300s，未设置超限丢弃 WAL 的选项。
生产两节点各持有独立 SSH key，仓库和数据库账号相互授权，固定 host key，关闭 SSH 自动追加 host keys（UpdateHostKeys=no），不允许 PTY/转发；
专用账号仍能运行所需远端命令。密钥在目标文件系统原地生成，避免 ext4 属性复制到 ZFS 失败。

查看仓库 `homelab-postgresql-backup.timer/service` 与
`pgbackrest --config=/etc/homelab-pgbackrest/repository.conf --stanza=prod info/check`。
首次实际 full 的 DB 22.7 MB、仓库备份集约 2.7 MB，仅代表当前空实例，不是未来业务容量估算。
独立的 dev 实例当前不备份。异地备份按维护者决定后置；本地 PVE 仓库不是异地或离线副本。

`tests/live_restore.py --run` 从真实仓库恢复到新临时目录，用私有 Unix socket 验证恢复实例可写与
Ayatori 角色，随后停库清理；不覆盖生产 PGDATA。全站恢复及接管旧 CNPG 不由此脚本自动执行。

## 监控与验收

现有 VictoriaMetrics/Alertmanager 已采集生产两节点 Patroni 原生指标，规则位于
`platform/observability/metrics/{scrapes,rules}/shared-postgresql.yaml`。覆盖成员不可采集、无可见主库、
多主、replica 未流复制及 PG 进程停止。没有部署另一套监控栈。dev SQL、备份年龄、证书和续签检查的主机采集已于 2026-09-27 部署，
新增规则已随 [PR #166](https://git.ddupan.top/panxiao81/homelab-infra/pulls/166) 合并并由 Flux 接管；
阈值、验证边界和排障见 [维护监控](../shared-data-monitoring/README.md)。

### SQL 级指标（2026-10-01 主机端上线）

每个实例在自身主机上运行 [prometheus-community/postgres_exporter](https://github.com/prometheus-community/postgres_exporter)
（`pg_exporter_version`，安装包与官方 `sha256sums.txt` 同源校验）：prod 为 laptop/pve1 的 `:9187`，
dev 为 laptop `:9188`，仅监听实例内网地址。exporter 以实例 OS 用户走本地 socket，由
`local all homelab_monitor peer map=monitor` 与 ident 映射登录到 `homelab_monitor`
（仅 `pg_monitor`、无密码、`CONNECTION LIMIT 3`）。这只约束 exporter 自己的查询，**不是隔离边界**：
同一 OS 用户仍可经 peer 以 superuser 登录，exporter 被攻破等同实例属主；systemd
`InaccessiblePaths` 只让它读不到数据目录、私钥与 pgpass。prod/dev 启用 `pg_stat_statements`。

规则 `platform/observability/metrics/rules/shared-postgresql-sql.yaml`（PrometheusRule）以上游
`postgres_mixin` 为底改写：采集/SQL 不通、复制回放落后 > 1 MiB（与 failover 阈值一致）、主库复制槽
保留 > 1 GiB、主库落在 pve1（HDD）超过 15 分钟、WAL 归档失败、XID/MXID 年龄、客户端连接 > 80%、空闲事务 > 10 分钟、事务 > 1 小时、
死锁、频繁请求 checkpoint。目标带 `env` 标签，Alertmanager 把 `env="dev"` 送到独立 dev 频道。

2026-10-01 验证：隔离集成测试覆盖 peer+ident 登录（主/备/dev）、读取 `pg_stat_statements`、
监控角色不可写；线上激活时两个 prod 成员按 pending 重启，时间线未变（未切换）；三个端点 `pg_up 1`、
无采集失败，exporter 各约 8 MiB；重跑 `changed=0`；vmagent Pod 可达三个端点。规则 promtool 场景通过。
`monitoring.yml --check` 不会显示 HUP、restart 与建角色（均为 command 任务），只能作参考。

2026-09-25 已验证：

- 真实 prod 主从、dev 初始化；Ayatori 管理账号 verify-full TLS/权限校验；生产稳定入口 SQL 写入。
- 配置第二次执行两主机 `changed=0`；备份配置三主机与代理重跑均 `changed=0`；实例秘密及 Ayatori 独立凭据重复执行不变更。
- 真实 SSH WAL 归档、首个 full、每日 timer；真实备份恢复到隔离实例并验证可写。
- `tests/live_failover.py --run` 停止主库服务，自动提升/入口写入、旧主重加入、计划回切后复制、探针清理全部通过；
  完整通过的一次恢复写入约 9.2 秒（首次观察 15.1 秒），是低负载演练结果，不是 SLA。
- 隔离 Docker 测试使用实际模板，另覆盖时间点恢复、DCS 多数派丢失后拒绝写入及管理权限合同。
- Terraform 最终 plan 无变更、Ansible lint、短期会话撤销测试与 Ayatori Kustomize 渲染通过。
- PG 续签 systemd 首次运行 Result=success，生产两主机证书检查与 SQL 验收均 `changed=0`；尚未强制演练证书临期轮换。

新 HDD 卷同步限制为各 10 MiB/s，入口 `limit-resync.yml`；同步已完成，副本 UpToDate。
此前 CT150 根卷 DRBD quorum 抖动导致 emergency_ro，已离线修复；详见 [etcd runbook](../etcd/README.md)。
限速后未再观察到同类故障，长期稳定性与唯一根因尚未确认。
