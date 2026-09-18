# Gitea dynamic runner controller

controller 接收 Gitea `workflow_job` webhook，对带 `[self-hosted, pod]` 或
`[self-hosted, vm]` 的 queued job 直接调用 OpenSandbox Lifecycle API。链路不使用
NATS、消息队列或平台侧 webhook worker。

```text
Gitea -> dynamic-runner-controller -> http://10.60.0.13:8080/v1/sandboxes
                                      -> ci-pod / ci-vm Pool
```

`10.60.0.13:8080` 是 VyOS 上的内网 HAProxy frontend，后端是 sandbox 节点的
`30080` NodePort。它只依赖现有跨网段路由，不暴露公网，也不经过 Cloudflare
Tunnel。controller 自身的 `192.168.10.127:8787` 仅供 Gitea webhook 和 sandbox
通过一次性 nonce 领取 registration token。

## Secret 边界

homelab 的 `ExternalSecret/dynamic-runner` 从既有 `ClusterSecretStore/openbao` 读取：

- `kv/k8s/opensandbox-api:api_key` -> `opensandbox-api-key`；
- `kv/k8s/dynamic-runner:webhook_secret` -> `webhook-secret`；
- `kv/k8s/gitea-runner:token` -> `token`。

API key 以只读文件挂载，controller 通过 `OPEN-SANDBOX-API-KEY` header 使用。不要把
key 复制到 Git、Lifecycle 请求、BatchSandbox 或 sandbox 集群 Secret。本目录不创建
Bao token，也不拥有 sandbox 平台侧的 ESO/Bao Terraform。

## 调度与身份

Lifecycle 请求只按 `ci-pod` / `ci-vm` 选择 Pool，并携带稳定的
`spiffe://ddupan.top/ci/<owner>/<repository>/<task>`。job ID 只用于日志和诊断 metadata。
runner labels 始终以 `self-hosted` 开头。

registration token 通过 controller 内存中的单次 nonce URL 投递。成功领取后 nonce
立即失效；沙箱结束、创建失败或超时时也会撤销。OpenSandbox DELETE 是最终的正常
回收路径，OpenSandbox timeout 是 controller 异常退出时的兜底。

完整部署和验收步骤见
[`platform/sandbox-ci-runners/README.md`](../sandbox-ci-runners/README.md)。
