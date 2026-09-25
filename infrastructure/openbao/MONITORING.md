# OpenBao 监控运维

受鉴权 `/v1/sys/metrics` 通过 vmagent 内的 Bao Agent 使用 Kubernetes 身份采集。
`metrics` policy 仅允许读取该路径；policy 和 role 由 `terraform/monitoring.tf` 管理。

Bao VM 的 Ubuntu `prometheus-node-exporter` 软件包监听 `192.168.10.8:9100`，
由 `ansible/roles/openbao_monitoring` 管理。仅供内网监控，不配置公共入口；
现场 UFW 未启用，故当前边界是 LAN 地址绑定，并非逐来源访问控制。
标准主机指标复用 `job=node-exporter` 的主机告警，额外标记 `node=bao1`。

首次部署前需要 bootstrap 已创建 `/etc/openbao/snapshot.token` 和快照目录。
只更新监控与快照运行文件（不会重启 Bao 或轮换 token）：

```bash
cd ansible
ansible-playbook monitor-openbao.yml --check
ansible-playbook monitor-openbao.yml
# 在 bao1 上执行一次真实快照，建立成功基线：
sudo systemctl start openbao-snapshot.service
```

快照脚本在 `/var/lib/prometheus/node-exporter/` 原子更新两个 `.prom` 文件：

- `openbao_snapshot_result.prom`：最近一次运行结果（0/1）及完成时间。
- `openbao_snapshot_success.prom`：最后一次成功生成完整本地快照的时间。

失败保留上次成功时间，先完成快照再删除超出保留数量的文件。
指标文件 root 写、exporter 只读；不包含 token、路径标签或快照内容。
首次成功前成功指标缺失，不用既有文件 mtime 冒充已验证成功。
Bao sealed 或 token 失效时，独立 exporter 仍能报告失败及超时。

`PrometheusRule/openbao` 包含：采集不可用（3 分钟）、内部健康异常（3 分钟）、
健康 gauge 缺失（5 分钟）、快照失败（5 分钟）、快照超过 36 小时或无成功记录
（持续 15 分钟）、快照监控缺失/损坏（5 分钟）。内部健康规则按当前**单节点**设计，
以后增加 standby 必须先调整 active 判定。快照指标仅证明本地任务成功，不能证明异地备份或可恢复性。

检查与恢复入口：

```bash
sudo systemctl status openbao-snapshot.timer openbao-snapshot.service prometheus-node-exporter
sudo journalctl -u openbao-snapshot.service -n 50 --no-pager
curl -fsS http://192.168.10.8:9100/metrics | grep '^openbao_snapshot_'
```

token 续期失败按[维护 runbook](https://git.ddupan.top/panxiao81/homelab-wiki/src/branch/main/guides/openbao-monitoring-maintenance.md)
受控轮换；不要通过反复重启 Bao 排障。回滚 exporter 或快照脚本无需重启 Bao。
回滚时同步撤回相应 ServiceMonitor/规则，否则缺指标告警会继续触发。

本地验证：

```bash
python3 -m unittest discover -s infrastructure/openbao/ansible/tests -v
# 需 PyYAML、Jinja2 和 promtool；已用 promtool 3.5.0 验证。
PATH=/path/to/promtool:$PATH bash platform/observability/metrics/tests/check-rules.sh
```

textfile 的原子发布方式遵循 [node_exporter 文档](https://github.com/prometheus/node_exporter#textfile-collector)。
