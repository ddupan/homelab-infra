# 集群外 SPIRE Agent

给不在任何 Kubernetes 集群里的主机发 SPIFFE 身份。当前只有 iam-login 的构建 runner：
pve1 LXC 104（`iam-spike-build`，Gitea runner 标签 `iam-build`，以 root 运行）。CI 用它取
`aud=zot` 的 JWT-SVID，把通过 Native 浏览器测试的同一个二进制推到
`zot-push.ad.ddupan.top/iam/iam-login`，发布不再单独编译。

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

`iam-build-ci-publish.yaml`：`spiffe://ddupan.top/ci/panxiao81/iam-login/publish`，parent 为
上面的 Agent ID，selector `unix:uid:0`。runner 以 root 运行全部 job，因此该 LXC 上任何 root 进程
（包括 PR 触发的 job）都能取得这个身份；它只能 create/update zot 的 `iam/iam-login`，不能删除，
部署仍以 homelab-infra 中固定的 digest 为准。runner 换成非 root 用户后应收紧 selector。
