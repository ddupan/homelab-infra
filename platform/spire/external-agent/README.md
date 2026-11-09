# 集群外 SPIRE Agent

给不在任何 Kubernetes 集群里的主机发 SPIFFE 身份。目前没有工作负载在用：iam-login 的 native
构建和发布 2026-11-09 迁回了 Pod，身份由 dynamic-runner 按 job 下发。pve1 LXC 104
（`iam-spike-build`，Gitea runner 标签 `iam-build`）还在跑 conformance，但不需要身份。

## 证明方式：join token

Server 的 `join_token` node attestor（`../values.yaml`）。token 一次性、短期，Agent 首次启动时
用它证明节点，之后用磁盘上的密钥自行续期 SVID。Agent ID 为
`spiffe://ddupan.top/spire/agent/join_token/<token>`，token 用掉后只是标识，可以写进 Git；
**未使用的 token 是凭据**，不打印、不提交，过期前用掉。

join token 的 Agent **不能重新证明**（`Can re-attest: false`）：它用当前 SVID（约 1 小时）自行续期，
主机停机超过 SVID 有效期，或 Agent 丢失 `/var/lib/spire-agent`（重装、重建 LXC），都无法再证明：重新生成 token、启动 Agent，
并把新的 Agent ID 更新到所有以它为 parent 的 ClusterStaticEntry。
2026-10-18 pve1 被 LINSTOR 驱逐后 LXC 停机，就是这样失效的（CI 发布报 `/run/spire-agent/agent.sock` 不存在）。
重新证明前先用 `spire-server bundle show` 刷新 `/etc/spire-agent/bootstrap-bundle.pem`：Server CA 轮换后，
旧 bundle 会让证明报 `certificate signed by unknown authority`。在 `pct exec` 里调用要写全路径
`/usr/local/bin/spire-agent`，那里的 PATH 不含 `/usr/local/bin`。

## 安装

二进制与 laptop 宿主机相同：SPIRE 官方 `linux-amd64-musl` 1.15.3 release 中的 `spire-agent`
（checksum 见 `../README.md`「宿主机本地开发身份」）。

```bash
install -m 0755 spire-agent /usr/local/bin/spire-agent
install -d -m 0700 /etc/spire-agent /var/lib/spire-agent
install -m 0644 agent.conf /etc/spire-agent/agent.conf
install -m 0644 spire-agent.service /etc/systemd/system/spire-agent.service
# 公开的 trust bundle，在 Server Pod 中导出
kubectl -n spire-server exec spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server bundle show > /etc/spire-agent/bootstrap-bundle.pem
# 首次证明：token 只经环境变量传给一次性运行，不写进 unit 或配置
kubectl -n spire-server exec spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server token generate -ttl 600   # 输出不要贴到日志或终端记录
```

首次证明不要把 token 放进命令行：从 `token generate` 的输出管道传入，写进一次性配置的
`join_token = "${JOIN_TOKEN}"` 并以 `-expandEnv` 运行，`spire-agent healthcheck` 通过后停止，删除该配置，再交给 systemd：
`systemctl enable --now spire-agent`。之后在 Server 上确认：
`spire-server agent list` 中出现该 Agent，记下 Agent ID。

## 身份

每个身份一个 `ClusterStaticEntry`，parent 为上面的 Agent ID，selector 用 `unix:uid` 限定到需要它的
用户。如果 runner 以 root 运行全部 job，`unix:uid:0` 等于把身份给该主机上所有 job，包括 PR 触发的。
