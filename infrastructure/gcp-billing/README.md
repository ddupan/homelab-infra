# GCP 账单：导出数据集和只读身份

账单金额由 `platform/observability/metrics/exporters/cloud-cost.yaml` 的 CronJob 从这里读取，写进
VictoriaMetrics，告警走现有 Alertmanager。预算金额在那个 CronJob 的 ConfigMap 里。

目前只在本地运行：`gcp-ci` 的 CI 接入还没合并。需要 `gcloud auth application-default login`，经
`.github/scripts/tf.py run infrastructure/gcp-billing/terraform <命令>` 运行。项目 `ddupan-ci` 和 SPIRE 联邦池
由 `../gcp-ci/terraform` 创建，要先于这个 root 存在。

## 费用

| 项目 | 费用 |
|---|---|
| 导出写入 BigQuery | 不收费 |
| BigQuery 存储 | 每月前 10 GiB 免费，超出约 $0.01/GiB 起 |
| BigQuery 查询 | 每月前 1 TiB 免费，超出约 $6.25/TiB；CronJob 一个月约 2.4 GB；项目 quota 封顶 30 GiB/天 |
| 服务账号、IAM、联邦 | 不收费 |

单项目的 Standard 导出是 MB 级，预期费用为 ¥0。价格来自 2026-11 的官方定价页，用前再核对。

## Apply 之后的手动步骤

控制台 **Billing → Billing export → BigQuery export**，**Standard usage cost** 和 **Detailed usage cost**
都选项目 `ddupan-ci`、数据集 `billing_export`。需要结算账户管理员权限，Terraform 没有管理这项设置的资源。
Detailed 表带 GKE cost allocation 的 Pod label，用于按仓库拆分 CI 费用（`../gcp-ci/terraform` 的集群）。

- 首次导出回填到上月初，数据要几小时才出现，最长 5 天补齐。
- 中途关闭导出或更换数据集都不会补历史，不要随意改动。
