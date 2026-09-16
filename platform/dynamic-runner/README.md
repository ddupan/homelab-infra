# Gitea dynamic runner controller

此目录只管理 homelab 中的 controller 部署。controller、worker、Cloud Hypervisor
launcher 和 guest runner 的源码与发布位于独立仓库
`panxiao81/gitea-dynamic-runner`。

当前 bootstrap controller 接收 Gitea `workflow_job` webhook，将 `[self-hosted, pod]` 和
`[self-hosted, vm]` 的 queued job 分别发布到 NATS。Pod worker 在本集群创建一次性
privileged host runner；Docker、BuildKit 和 kind 由 workflow 自行 setup。内部
endpoint：

```text
http://dynamic-runner-controller.dynamic-runner.svc.cluster.local:8787/webhook
```

OpenBao 路径：

- `kv/k8s/nats.ci_producer_password`：已有 NATS producer 密码。
- `kv/k8s/nats.ci_worker_password`：已有 NATS worker 密码。
- `kv/k8s/microvm-runner.webhook_secret`：Gitea webhook HMAC secret；这是已有 Bao
  路径，资源重命名不迁移 secret 数据。
- `kv/k8s/gitea-runner.token`：现有 instance runner registration token。

首期 controller 与 runner 镜像由 laptop 本机构建后导入 k3s containerd，作为 CI
发布链路建立前的 bootstrap。部署使用 `imagePullPolicy: Never`。正式发布 workflow
获得专用 SPIFFE ID 后，必须将 image 改为 zot digest 并移除本地导入步骤。

## 身份绑定

queued webhook 只负责创建没有业务身份的 Pod。runner 实际领取任务后，Gitea 的
`in_progress` webhook 会携带实际 `runner_name`；controller 将 binding 消息发布到
NATS，Pod worker 再给对应 Pod 添加：

```text
ci.ddupan.top/identity-bound=true
ci.ddupan.top/spiffe-path=<owner>/<repository>/<percent-encoded-job-name>
```

`ClusterSPIFFEID/gitea-dynamic-runner` 只匹配已经绑定的 Pod，并签发
`spiffe://ddupan.top/ci/<owner>/<repository>/<job-name>`。runner 的 job-start hook 在
SVID 可用之前不会放行第一步，因此不能根据 queued 事件错配身份。

每个 runner Pod 使用 `gitea-dynamic-runner` ServiceAccount。该 ServiceAccount 没有
Kubernetes API 权限；只有 `dynamic-runner-pod-worker` ServiceAccount 能在本 namespace
create/get/patch/delete Pod。

长期实现将由兼容 Gitea RunnerService 的 scheduler 直接领取 task，再交给 Pod/VM
executor；届时删除 webhook、临时 runner 注册和 identity binding 消息。跟踪见
`panxiao81/gitea-dynamic-runner` issue #7。

Gitea webhook 只订阅 `workflow_job`，content type 使用 JSON，secret 与 Bao 中值
一致。不要启用 `send_everything`，否则 controller 会收到无关仓库事件。
