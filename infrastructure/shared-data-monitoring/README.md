# 共享数据服务维护监控

为 laptop、etcd-pve1（10.60.0.20）、etcd-pve2（10.60.0.21）补齐备份、磁盘证书、
续签检查与 dev SQL 的指标。复用现有 VictoriaMetrics/Alertmanager；不部署新监控栈。
实现由 [PR #166](https://git.ddupan.top/panxiao81/homelab-infra/pulls/166) 发布。

2026-09-27：三个主机端已部署并验证，Ansible 重跑均 `changed=0`；vmagent Pod 能访问三个
内网 `:9109/metrics`。抓取声明和八条规则尚待 PR 合并，不能视为已启用告警。

## 采集和阈值

每分钟执行 `homelab-data-collect.service`，读取明确清单并原子替换
`/var/lib/homelab-data-monitoring/health.prom`。每项检查失败输出零值及 `check_success=0`，
不沿用旧成功值；完整采集时间用于发现任务停止或文件缺失。端点不暴露密码、token、私钥。

| 项目 | 证据 | 告警 |
|---|---|---|
| etcd 快照 | 每成员已完成 `.db` 文件 mtime，排除 `.partial` | 超过 36 小时 warning |
| PG full 备份 | 仓库本地 pgBackRest JSON 中无错误 full 的完成时间 | 超过 36 小时 warning |
| 证书 | 显式清单包含 server/peer/admin/gateway/PG etcd client/CA；取完整 PEM 链最早到期时间 | 不足 10 天 warning；不足 3 天或无法读取 critical |
| 续签检查 | laptop 两个 renew service 的成功退出时间及 timer active | 失败、停用或超过 36 小时 warning |
| dev | 本地 socket、pgdev peer 身份，只读 SQL 检查非 recovery 且非只读 | 连续异常 3 分钟 warning |
| 采集链路 | exporter up、单项检查、textfile 错误、完整采集时间 | 失败或心跳超过 3 分钟后持续 3 分钟 warning |

证书在不足 14 天时由原自动续签任务处理，10 天阈值给重试留出余量；critical 不重复触发 warning。
36 小时适用于现有每日快照/full/续签检查计划。dev 未新增备份，异地备份仍后置。

node_exporter 当前版本为 1.9.1；下载包与官方 `sha256sums.txt` 均由
`data_monitor_exporter_version` 生成，Ansible 按包名匹配摘要，升级只改版本变量；保留上游 LICENSE。
仅启用 textfile，使用 DynamicUser，绑定各主机内网地址的 9109，与现有 9100 不冲突。
采集程序以 root 运行，以便读取快照元数据和切换为 pgdev/pgbackup；systemd 限制文件系统写入
到 textfile 目录，限制执行时间与内存。无需 Bao 登录；数据库和 etcd 不因部署监控重启。
采集并非常驻进程；laptop 上 exporter 当前 MemoryCurrent 约 2.6 MiB，仅作现场开销参考。

## 部署和验证

在 PR 分支或合并后的完整 checkout 中执行：

```bash
cd infrastructure/shared-data-monitoring/ansible
ansible-playbook site.yml
```

本机需要免交互 sudo，远程使用已有 root SSH；配置不包含秘密。当前实现仅支持 Linux amd64，
依赖现有 Python 3、OpenSSL、systemd、PG 客户端和 pgBackRest。下载 exporter 需要访问 GitHub。

只读查看结果：

```bash
curl --fail http://192.168.10.127:9109/metrics
sudo systemctl status homelab-data-collect.timer homelab-data-exporter.service
sudo journalctl -u homelab-data-collect.service --since '2 hours ago'
```

主机端 `check_success` 应全为 1、`dev_sql_ready=1`，`node_textfile_scrape_error=0`。
合并后检查 `up{job="shared-data-maintenance"}` 三个目标及 `shared-data-maintenance` 规则组。
告警声明使用 `monitoring.coreos.com/v1` 的 `PrometheusRule`，由现有 converter 生成 VMRule；
静态主机抓取使用 VMStaticScrape。Kubernetes 资源由现有 observability Kustomization 纳管；
主机端由此 Ansible 独立维护。

2026-09-27 验证：6 项采集测试、12 个新增 promtool 场景及既有规则回归通过；Ansible lint
零失败零告警；Kustomize 渲染通过；三主机实际采集和 vmagent 网络路径通过。未停止业务来测试告警。

## 故障入口与边界

- 采集停止：先查 exporter 和 collect timer/service，再看 `.prom` 的 collection timestamp。
- 备份陈旧：etcd 查 `homelab-etcd-snapshot`；PG 仓库查 `homelab-postgresql-backup`。
  不以 touch 文件消除告警。快照年龄依赖完成文件 mtime，手工复制会改变证据，不能冒充新备份。
- 证书或续签异常：查 laptop 的 `homelab-etcd-renew` / `homelab-postgresql-renew`；
  修复 Bao/SPIRE/网络或受限身份后重跑原续签入口，不删除现有证书或重置数据库。
- dev SQL 失败：查 `homelab-postgresql-dev`、磁盘与 socket，再核对本地 peer 认证。

备份年龄不能证明恢复能力或 WAL 连续性；定期隔离恢复演练仍必要。证书指标读取磁盘文件，
不证明运行进程已重载该证书。dev 检查不验证外部 DNS/TLS 路径、不执行写入。
SQL 级 exporter、异地备份及应用迁移不在本次范围。

跨服务状态见 [共享 PG wiki](https://git.ddupan.top/panxiao81/homelab-wiki/src/branch/main/services/shared-postgresql.md)。
