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
ansible-playbook converge.yml --check -l 'etcd-pve1.lab.ddupan.top,localhost'   # why-run，不改动
ansible-playbook converge.yml -l 'etcd-pve1.lab.ddupan.top,localhost'           # apply
```

`-l` 必须带上 `localhost`：第一个 play 在 laptop 上导出 policy 归档，被 limit 排除时它
不运行，后面的 play 会因找不到归档失败。

更新 lock（升级 cookbook = 改 policy 里的 tag，然后提交 lock）：

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/policies:/p" -w /p \
  docker.io/cincproject/workstation:26.3.0 cinc install base.rb
```

play 只从**已提交的 lock** 导出，不会重新解析版本。工具链用 Cinc Workstation 容器，laptop
不需要 Ruby。

## SPIRE agent（每个节点）

`homelab_base` 安装 SPIRE agent，以 **x509pop** 向 `spire-server.lab.ddupan.top` 证明。节点证书来自
Bao 的独立 CA `pki-spire-nodes`，走 ACME（lego，http-01），名字是 `<hostname>.lab.ddupan.top`。

- **首次 enrollment 由本 play 完成**（证书不存在时）：检查 lab 名解析到本机 → 从 Server 导出
  bootstrap bundle → 用操作者的 Bao token 铸**一次性 EAB** → 只经环境变量交给节点上的
  `spire-node-cert` → 启动 agent 并等 healthcheck。需要 `BAO_TOKEN`（laptop 上 SPIFFE
  `local-development` 登录即可）；此后的运行都不需要任何 token。
- **续期**：节点上的 `spire-node-cert.timer` 每天运行 `lego run`（剩 30 天时续期），不需要 EAB。
- workload entry 一律挂在 node alias `spiffe://ddupan.top/node/<名字>` 下（`platform/spire/spire-node-aliases.yaml`），
  不要挂 agent ID：它包含证书指纹，每次续期都会变。新节点要在那里加一个 alias。

## 节点

| 节点 | policy | 加入日期 |
|---|---|---|
| etcd-pve1 | base | 2026-10-09 |
| etcd-pve2 | base | 2026-10-09 |
| lb-prod-1、lb-prod-2 | loadbalancer-prod | 待部署 |
| lb-dev-1、lb-dev-2 | loadbalancer-dev | 待部署 |
| ayatori-dev | ayatori-dev | 迁移中（原 infrastructure/ayatori/ansible） |

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
