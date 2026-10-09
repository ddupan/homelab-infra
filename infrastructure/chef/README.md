# Cinc 节点配置（部署声明）

cookbook 代码在 [homelab-cookbooks](https://git.ddupan.top/panxiao81/homelab-cookbooks)；
本目录只放部署声明：policy、它的 lock，以及推送脚本。

## 模型

- **没有 Cinc Server，也不自动应用。** `converge.sh` 从 laptop 经 ssh 推送 policy 归档并运行，
  节奏和 Ansible 一样：PR 合并后手动执行。
- **agentless 安装客户端**：节点没有 Cinc 或版本不符时，laptop 先按 omnitruck 公布的 sha256
  下载 `.deb`（缓存在 `~/.cache/homelab-cinc/`），再 scp 过去安装；节点不需要访问外网。
  版本由 `converge.sh` 的 `CINC_VERSION` 决定。
- **自动检测漂移**：`homelab_base` 在每个节点装一个每日 timer，对最后一次 apply 的 policy
  （`/var/lib/homelab-cinc/policy`）做 why-run，不做任何修改。结果写进 node_exporter textfile，
  `CincDriftDetected` 告警（`platform/observability/metrics/rules/cinc.yaml`）。
  apply 之后脚本会立即触发一次检查刷新指标。
- 节点发现以 DNS 为准（`lab.ddupan.top`），host 参数就是 DNS 名。

## 用法

```bash
cd infrastructure/chef
./converge.sh lock base                                         # 解析并写 policies/base.lock.json（提交）
./converge.sh run base --why-run etcd-pve1.lab.ddupan.top       # 预览：不改动，也不替换已应用的 policy
./converge.sh run base etcd-pve1.lab.ddupan.top                 # 应用
```

- 只从**已提交的 lock** 导出；`run` 不会重新解析版本。升级 cookbook = 改 policy 里的 tag →
  `lock` → 提交 → PR。
- 工具链用 Cinc Workstation 容器（`docker`），laptop 不需要 Ruby。
- 需要 root ssh 到节点，`known_hosts` 里要有 DNS 名（首次可与已信任的 IP 条目比对后添加）。

## 节点

| 节点 | policy | 加入日期 |
|---|---|---|
| etcd-pve1 | base | 2026-10-09 |

新节点加入时同时把 `<名字>:9100` 加进 `platform/observability/metrics/scrapes/cinc-nodes.yaml`。

## 已知限制

- `homelab_cinc_resources_updated` 统计的是**顶层** resource（每个 custom resource 计 1），
  不是 Cinc 输出里含嵌套的总数；作为漂移信号（> 0）足够。
- LXC 里 ohai 读不到 DMI，每次运行会打一行 `shard_seed ... dmidecode` ERROR，无害。
