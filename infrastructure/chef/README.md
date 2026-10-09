# Cinc 节点配置（部署声明）

cookbook 代码在 [homelab-cookbooks](https://git.ddupan.top/panxiao81/homelab-cookbooks)；
本目录只放部署声明：policy、它的 lock，以及推送它们的 Ansible play。

## 模型

- **没有 Cinc Server，也不自动应用。** `ansible/converge.yml` 在 PR 合并后手动执行，节奏和
  其他 Ansible play 一样。Ansible 只负责安装客户端和推送 policy 归档，配置本身由 Cinc 完成。
- **`--check` 就是 why-run。** `changed` 表示 Cinc 更新了（或将会更新）resource，所以
  "第二次 apply `changed=0`" 仍是验收标准。
- **客户端安装**：laptop 按 omnitruck 公布的 sha256 下载 `.deb`（缓存在
  `~/.cache/homelab-cinc/`），再复制到节点安装；节点不需要访问外网。版本见
  `ansible/inventory/group_vars/all.yml` 的 `cinc_version`。
- **自动检测漂移**：`homelab_base` 在每个节点装一个每日 timer，对最后一次 apply 的 policy
  （`/var/lib/homelab-cinc/policy`）做 why-run，不做修改；结果经 node_exporter textfile 触发
  `CincDriftDetected`（`platform/observability/metrics/rules/cinc.yaml`）。apply 后 play 立即
  触发一次检查以刷新指标。
- 节点发现以 DNS 为准（`lab.ddupan.top`），inventory 里就是 DNS 名。

## 用法

```bash
cd infrastructure/chef/ansible
ansible-playbook converge.yml --check -l etcd-pve1.lab.ddupan.top   # why-run，不改动
ansible-playbook converge.yml -l etcd-pve1.lab.ddupan.top           # apply
```

更新 lock（升级 cookbook = 改 policy 里的 tag，然后提交 lock）：

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/policies:/p" -w /p \
  docker.io/cincproject/workstation:26.3.0 cinc install base.rb
```

play 只从**已提交的 lock** 导出，不会重新解析版本。工具链用 Cinc Workstation 容器，laptop
不需要 Ruby。

## 节点

| 节点 | policy | 加入日期 |
|---|---|---|
| etcd-pve1 | base | 2026-10-09 |
| etcd-pve2 | base | 2026-10-09 |

新节点：加进 `ansible/inventory/hosts.yml`，并把 `<名字>:9100` 加进
`platform/observability/metrics/scrapes/cinc-nodes.yaml`。

## 陷阱与已知限制

- **Cinc 通过 `$PWD` 找 `.cinc/config.rb`**，不是进程的实际工作目录。Ansible 的 `chdir`
  不会设置 `$PWD`，于是 Cinc 找不到配置，以空 run list "成功" 运行、0 个更新——一个静默的
  假阴性。play 因此显式传 `-c`，并在出现 empty run list 时失败。（systemd 的
  `WorkingDirectory=` 会设置 `$PWD`，所以漂移 timer 不受影响，已在 journal 确认收敛 19 个 resource。）
- **Cinc 自带的 agentless 模式（`cinc-client -t`）2026-10-09 试过，弃用**：19.3.14 中它通过
  SSH 读取远端文件 checksum 出错，每次运行都重写文件、reload sshd、重启 node_exporter，
  不幂等，why-run 也因此永远报漂移。新版本可重新评估。
- `homelab_cinc_resources_updated` 统计**顶层** resource（每个 custom resource 计 1），
  不是 Cinc 输出里含嵌套的总数；作为漂移信号（> 0）足够。
- LXC 里 ohai 读不到 DMI，每次运行会打一行 `shard_seed ... dmidecode` ERROR，无害。
