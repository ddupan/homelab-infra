# Cinc 节点配置（部署声明）

cookbook 代码在 [homelab-cookbooks](https://git.ddupan.top/panxiao81/homelab-cookbooks)；
本目录只放部署声明：policy、它的 lock，以及推送它们的执行器 `converge.py`。

## 模型

- **没有 Cinc Server；CI 执行，合并即 apply**（`.github/workflows/chef.yml`，与 terraform 一样以
  main 为期望状态）。PR 上对受影响的节点 why-run 并把汇总贴成评论；合并后对同一范围 apply。
  范围按改动计算：policy 的 `.rb`/lock 只影响自己的节点，`converge.py`、inventory 和 workflow
  影响全部节点，README、测试、`enroll.yml` 不触发收敛。也可以手动触发（workflow_dispatch，
  可选 limit，默认只 why-run）。
- `converge.py` 从已提交的 lock 导出 policy 归档，经 SSH 并行推到各节点跑 `cinc-client -z`，
  日志按主机前缀实时输出，最后打印汇总表，任一节点失败即非零退出。配置本身由 Cinc 完成。
- **CI 的 SSH**：每个 job 生成临时 key，用 SPIFFE 身份（role `ci-converge`）向 Bao 签 30 分钟证书，
  principal 为 `root,panxiao81`，与 inventory 的登录用户一致。主机密钥来自 `known_hosts`
  （加入时与操作者已信任的记录核对），不做 TOFU。**新节点要同时加进 `known_hosts`。**
- **`--why-run` 不改动任何节点。** 汇总表的数字是 Cinc 更新了（或将会更新）的 resource 数，
  "第二次 apply 全部为 0" 仍是验收标准。
- **节点只需要能 SSH 进去**：客户端缺失或版本不对时，执行器按 omnitruck 公布的 sha256 下载
  `.deb`（缓存在 `~/.cache/homelab-cinc/`），经 SSH 传到节点安装；节点不需要访问外网。版本见
  `ansible/inventory/group_vars/all.yml` 的 `cinc_version`（执行器也读这个文件，值里不能用 Jinja）。
- **自动检测漂移**：`homelab_base` 在每个节点装一个每日 timer，对最后一次 apply 的 policy
  （`/var/lib/homelab-cinc/policy`）做 why-run，不做修改；结果经 node_exporter textfile 触发
  `CincDriftDetected`（`platform/observability/metrics/rules/cinc.yaml`）。apply 后执行器立即
  触发一次检查以刷新指标。
- 节点发现以 DNS 为准（`lab.ddupan.top`），inventory 里就是 DNS 名。

## 用法

```bash
cd infrastructure/chef
./converge.py --why-run                  # 全部节点 why-run，不改动
./converge.py -l etcd-pve1               # apply 一台（短名、FQDN 或 policy 名，逗号分隔）
./converge.py -l loadbalancer-prod       # apply 一个 policy 的全部节点
```

需要 `uv` 和 docker（Cinc Workstation 容器导出归档）。SSH 用本机的 key/agent；`-i <key>`
指定私钥，同目录的 `<key>-cert.pub`（Bao 签发的证书）会被自动使用。单元测试：
`uv run --with pyyaml --with pytest python -m pytest infrastructure/chef/test_converge.py`。

cookbook 升级通常由 Renovate 发起：homelab-cookbooks 发版（release-please 的 `<cookbook>-v<版本>` tag）后，
`*-dev` policy 的升级自动开 PR，Prod 以及没有 Dev 环境的 policy（etcd、samba-dc）要在 Dependency Dashboard
里批准才开（`renovate/promote-*` 分支）。lock 由 `.github/workflows/regenerate.yml` 在 Renovate 的分支上
`cinc update` 后以 ddupan-bot 提交，PR 上的 why-run 随后重跑。

手动更新 lock（升级 cookbook = 改 policy 里的 `= 版本`，然后提交 lock）。cookbook 来自 Gitea 的 Chef
registry（`default_source :supermarket`），按 cookbook 自己的版本固定。要用 `cinc update`：已有 lock 时
`cinc install` 直接按旧 lock 安装，不会重新解析。

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/policies:/p" -w /p \
  docker.io/cincproject/workstation:26.3.0 cinc update <policy>.rb
```

只改 policy 的属性时用 `cinc update --attributes <policy>.rb`，不会重新解析 cookbook。它要求
cookbook 已在本地缓存，所以在同一个容器里先 `cinc install <policy>.rb`，否则会报
`CachedCookbookNotFound`，并把 lock 清空。

执行器只从**已提交的 lock** 导出，不会重新解析版本。工具链用 Cinc Workstation 容器，laptop
不需要 Ruby。

## SPIRE agent（每个节点）

`homelab_base` 安装 SPIRE agent，以 **x509pop** 向 `spire-server.lab.ddupan.top` 证明。节点证书来自
Bao 的独立 CA `pki-spire-nodes`，走 ACME（lego，http-01），名字是 `<hostname>.lab.ddupan.top`。

- **首次 enrollment 由 `ansible/enroll.yml` 完成**（证书不存在时；执行器在汇总表里提示哪些节点还没做）：在节点首次 apply 之后运行
  `BAO_TOKEN=... ansible-playbook enroll.yml -l <host>`。流程：检查 lab 名解析到本机 → 从 Server 导出
  bootstrap bundle → 用操作者的 Bao token 铸**一次性 EAB** → 只经环境变量交给节点上的
  `spire-node-cert` → 启动 agent 并等 healthcheck。需要 `BAO_TOKEN`（laptop 上 SPIFFE
  `local-development` 登录即可）；此后的运行都不需要任何 token。
- **续期**：节点上的 `spire-node-cert.timer` 每天运行 `lego run`（剩 30 天时续期），不需要 EAB。

### Ayatori 节点 agent 的首次签发（join）

compute、loadbalancer 节点上的 Ayatori agent 以 CSR 证书加入控制面（Ayatori ADR-0021/0022）。cookbook
只装 agent 并创建属于 agent 用户的凭据目录，**不碰凭据**；第一张证书由 `ansible/join.yml` 完成，与
enrollment 一样是一次性操作、不从 CI 运行：

```
ansible-playbook join.yml -l lb-dev-1.lab.ddupan.top \
  -e ayatori_role=loadbalancer -e ayatori_control_plane=ayatori-dev.lab.ddupan.top
```

在控制面上建 15 分钟的 bootstrap token，把 `bootstrap-kubeconfig` 写进节点的凭据目录，再用控制面
正在运行的 manager 镜像执行 `client-credentials approve-bootstrap`：只批准以这个 token 提交、且申请的
恰好是 `system:ayatori:node:<节点>` 与该角色组的 CSR——**这次批准就是准入**。私钥只在节点上生成；
续签由 agent 自己完成。证书已存在时跳过；同一台主机的每个角色各 join 一次。LB 主机在 join 之前照常
宣告 VIP。
- workload entry 一律挂在 node alias `spiffe://ddupan.top/node/<名字>` 下（`platform/spire/spire-node-aliases.yaml`），
  不要挂 agent ID：它包含证书指纹，每次续期都会变。新节点要在那里加一个 alias。

## 节点

| 节点 | policy | 加入日期 |
|---|---|---|
| etcd-pve1 | etcd-pve1（含共享数据维护指标，2026-11-04） | 2026-10-09 |
| etcd-pve2 | etcd-pve2（含共享数据维护指标，2026-11-04） | 2026-10-09 |
| etcd-pve3 | etcd-pve3（取代 etcd-laptop，#570） | 2026-11-04 |
| lb-prod-1、lb-prod-2 | loadbalancer-prod | 待部署 |
| lb-dev-1、lb-dev-2 | loadbalancer-dev | 待部署 |
| ayatori-dev | ayatori-dev | 2026-11-03 |
| ayatori-prod | ayatori-prod | 2026-11-03 |
| dc1 | samba-dc | 2026-11-04 |
| compute-dev-1、compute-dev-2、compute-dev-3 | compute-dev（暂只有节点基线） | 2026-11-13 |

新节点：加进 `ansible/inventory/hosts.yml` 和 `known_hosts`，并把 `<名字>:9100` 加进
`platform/observability/metrics/scrapes/cinc-nodes.yaml`。

## 陷阱与已知限制

- **Cinc 通过 `$PWD` 找 `.cinc/config.rb`**，不是进程的实际工作目录。Ansible 的 `chdir`
  不会设置 `$PWD`，于是 Cinc 找不到配置，以空 run list "成功" 运行、0 个更新——一个静默的
  假阴性。执行器因此显式传 `-c`，并在出现 empty run list 时失败。（systemd 的
  `WorkingDirectory=` 会设置 `$PWD`，所以漂移 timer 不受影响，已在 journal 确认收敛 19 个 resource。）
- **Cinc 自带的 agentless 模式（`cinc-client -t`）2026-10-09 试过，弃用**：19.3.14 中它通过
  SSH 读取远端文件 checksum 出错，每次运行都重写文件、reload sshd、重启 node_exporter，
  不幂等，why-run 也因此永远报漂移。新版本可重新评估。
- `homelab_cinc_resources_updated` 统计**顶层** resource（每个 custom resource 计 1），
  不是 Cinc 输出里含嵌套的总数；作为漂移信号（> 0）足够。
- LXC 里 ohai 读不到 DMI，每次运行会打一行 `shard_seed ... dmidecode` ERROR，无害。
