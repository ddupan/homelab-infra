# Gitea kind microVM runner

`kind-microvm` 是专门运行 kind / nested Kubernetes CI 的 runner label。每个 job
独占一台 Cloud Hypervisor VM；guest 内直接运行 Docker 与 ephemeral Gitea Runner，
不经过 Kata。VM 完成一个 job 后关机，临时 COW 磁盘随即删除。

集群内的 `controller.py` 消费 Gitea `workflow_job` webhook。仅当
`action=queued` 且 `workflow_job.labels` 包含 `kind-microvm` 时，向 NATS JetStream
的 `ci.runner.kind-microvm` subject 发布消息。`workflow_job.id` 写入
`Nats-Msg-Id`，重复 webhook 不会生成第二个任务。

pve2 LXC 内的 `worker.py` 使用 durable pull consumer 领取消息。领取后启动一台
microVM，运行期间每分钟发送 `InProgress`；VM/ephemeral runner 正常退出才 ACK，
启动失败则 NAK 并延迟重试。当前 `RUNNER_CAPACITY=1` 只是 pve2 的资源配置；以后可
提高单 worker capacity，或在其他宿主机增加共享同一 durable consumer 的 worker，
而无需修改 webhook/controller。相同 runner 类型必须共享 durable；WorkQueue stream
不允许多个 consumer 使用重叠的 subject filter。

worker 的凭据位于：

```text
/etc/microvm-runner/registration-token
/etc/microvm-runner/nats-password
```

二者必须为 root-only 文件，不能写入镜像、cloud-init seed 或仓库。worker 为每次
启动生成一次性 nonce；guest 只能从 TAP 网段请求一次 registration token，请求后
立即从 worker 内存删除。runner 注册成功后删除 guest 内的 token 文件，再启动
daemon。这样 job 无法从 seed disk 或 Docker inspect 取回可复用 registration token。

NATS stream 使用 `WorkQueuePolicy`，ACK 后立即删除消息；同时限制为 24 小时、
10000 条和 256 MiB，异常积压也不会无限增长。NATS 平台配置见
`../../platform/nats/`。

2026-09-16 PoC 已验证：Cloud Hypervisor v52.0、Ubuntu 24.04、4 vCPU、3 GiB RAM、
10 GiB COW disk 中，Docker 29.1.3 成功创建 kind v0.27.0 / Kubernetes v1.32.2
集群，并运行 `busybox:1.37` smoke Pod。冷启动约 20 秒。pve2 资源只允许一台：
VMM cgroup（guest RAM 与 page cache）峰值约 6.2 GiB。

正式启用前还需要安装 launcher、制作不含凭据的基础镜像、部署 controller，并在
Gitea 配置只发送 `workflow_job` 的 instance/organization webhook。workflow 使用：

```yaml
runs-on: kind-microvm
```

当前 pve2 配置：

```ini
RUNNER_CAPACITY=1
NATS_DURABLE=kind-microvm
RUNNER_MAX_INFLIGHT=64
```
