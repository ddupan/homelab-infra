# Docker 地址池与 DN42

DN42 使用 `172.20.0.0/14`。laptop 的 Docker 默认地址池改为 `172.28.0.0/16`，
按 `/24` 分配新 bridge，避免本地直连路由与 DN42 前缀重叠。
`ansible/site.yml` 合并现有 daemon.json，保留 NVIDIA runtime；先热加载 live-restore，
再重启 daemon 使默认地址池生效，避免已有容器随 daemon 停止。

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-docker ansible-playbook -i localhost, infrastructure/docker/ansible/site.yml --check --diff
ANSIBLE_LOCAL_TEMP=/tmp/ansible-docker ansible-playbook -i localhost, infrastructure/docker/ansible/site.yml
```

已有网络不会自动换地址。本次单独迁移结果：

| 网络 | 原地址 | 当前地址/状态 |
|---|---|---|
| blocky_default | 172.20.0.0/16 | 172.28.0.0/24，Compose 明确声明 |
| ps3netsrv_default | 172.21.0.0/16 | 172.28.1.0/24，Compose 明确声明 |
| research-auto_default | 172.22.0.0/16 | 172.28.2.0/24，仓库外 research-auto Compose 明确声明 |
| netboot_default | 172.23.0.0/16 | 删除无端点的遗留网络；netboot 两个容器均使用 host 网络 |

Blocky 健康检查与 DNS 查询通过；ps3netsrv 运行，游戏数据挂载保留。
research-auto 的 postgres 容器仅 create、未启动，原命名卷 `research-auto_postgres_data` 保留。

旧运行容器曾引用仓库重组前的 `/home/panxiao81/services/<app>` 挂载路径；
本次 Blocky 已用 `apps/blocky` 路径重建，netboot 等未重建的容器仍需在重建时使用当前 Compose。
不要在未检查 bind mount 路径的情况下关闭 live-restore 并重启所有容器。
