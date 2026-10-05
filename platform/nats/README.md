# NATS

共享的轻量消息基础设施。首期为 Gitea microVM runner 提供 JetStream work queue，
但 Account、subject 与部署位置均不与 CI controller 绑定，其他服务可按独立 Account
复用。

**当前状态：已缩容到 0（2026-10-05）。** 唯一的使用方 gitea-dynamic-runner 已改为每个
worker 用自己的 Gitea runner registration 直接领取 task，不再使用 JetStream 队列，CI
Account 没有任何客户端。`values.yaml` 用 `statefulSet.merge.spec.replicas: 0` 停掉服务，
配置、PVC 与 Service 保留以便回滚；NATS 告警规则与单测已删除。重新启用时把 replicas
改回 1，并从 git 历史恢复 `NatsMetricsUnavailable`、`NatsJetStream*`、
`NatsSlowConsumers` 及其测试。若确认不再需要，再单独移除整个目录与 PVC。

## 当前拓扑

- 单节点 NATS；当前 homelab 没有资源运行有意义的三副本 JetStream quorum。
- JetStream file store 使用 `localpv-zfs-ceph`，PVC 2 GiB。
- 服务通过 k3s ServiceLB 在 `nats.ad.ddupan.top:4222` 暴露给内网；集群内客户端
  使用 `nats.nats.svc.cluster.local:4222`。访问控制由 TLS、Account 与用户权限负责，
  不额外维护易漂移的源 IP 白名单。
- TLS 证书由 `bao-acme` 签发。PVE 节点已信任内部 CA。
- `bao-server` PKI role 只接受 RSA CSR，因此 Certificate 使用 RSA 2048；不要改成
  ECDSA，ACME challenge 会成功但 finalize 会以 `role requires keys of type rsa` 失败。
- `SYS` Account 用于管理；`CI` Account 启用 JetStream，存储上限 1 GiB。

Account 内的 JetStream 配额会原样进入 `nats.conf`，必须使用 NATS 的 `MB`/`GB`
格式；PVC 等 Kubernetes resource quantity 才使用 `Mi`/`Gi`。

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

controller 使用 `CI_RUNNER` stream：`ci.runner.>`、
`WorkQueuePolicy`、file storage、24h/10000 条/256 MiB 上限。每类 runner 使用独立
placement subject 和 durable pull consumer；assignment v2 subject 为
`ci.runner.<workload-class>.<driver>`，当前为 `ci.runner.container.kubernetes` 与
`ci.runner.vm.opensandbox`。同 placement 的多个 worker 共享 durable consumer。ACK 后消息立即
删除，不保存 CI 历史。

## 验证

```bash
kubectl -n nats get helmrelease,pod,pvc,certificate,externalsecret
kubectl -n nats logs statefulset/nats -c nats
```
