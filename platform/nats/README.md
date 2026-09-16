# NATS

共享的轻量消息基础设施。首期为 Gitea microVM runner 提供 JetStream work queue，
但 Account、subject 与部署位置均不与 CI controller 绑定，其他服务可按独立 Account
复用。

## 当前拓扑

- 单节点 NATS；当前 homelab 没有资源运行有意义的三副本 JetStream quorum。
- JetStream file store 使用 `localpv-zfs-ceph`，PVC 2 GiB。
- 服务通过 k3s ServiceLB 在 `nats.ad.ddupan.top:4222` 暴露给内网；集群内客户端
  使用 `nats.nats.svc.cluster.local:4222`。访问控制由 TLS、Account 与用户权限负责，
  不额外维护易漂移的源 IP 白名单。
- TLS 证书由 `bao-acme` 签发。PVE 节点已信任内部 CA。
- `SYS` Account 用于管理；`CI` Account 启用 JetStream，存储上限 1 GiB。
- Prometheus exporter 已启用，但不创建 `PodMonitor`：集群使用 VictoriaMetrics
  Operator CRD，后续以 `VMServiceScrape` 接入。

首期使用静态用户，密码只存在 OpenBao `kv/k8s/nats`：

```text
sys_password
ci_producer_password
ci_worker_password
```

`ci-producer` 只能发布 `ci.runner.>` 并调用必要的 JetStream API；`ci-worker`
只能调用 JetStream pull/ACK API。二者都不能读取另一个 Account 的 subject。

后续 SPIRE/Auth Callout 动态认证见 homelab-infra issue #56。该迁移只替换连接
凭据，不改变 Account、stream、subject 或 consumer。

## CI stream 约定

controller 首次启动时幂等创建 `CI_RUNNER` stream：`ci.runner.*`、
`WorkQueuePolicy`、file storage、24h/10000 条/256 MiB 上限。每类 runner 使用独立
subject 和 durable pull consumer；同类型的多个 worker 共享 durable consumer。
ACK 后消息立即删除，不保存 CI 历史。

## 验证

```bash
kubectl -n nats get helmrelease,pod,pvc,certificate,externalsecret
kubectl -n nats logs statefulset/nats -c nats
```
