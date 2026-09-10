# Gitea Actions runner

This is the bootstrap runner for Gitea Actions. One persistent runner Pod accepts
up to four jobs; each job runs in a dynamically created container inside a
Docker-in-Docker daemon. The official chart runs DinD privileged. Rootless DinD
would still be privileged and is blocked by the node's AppArmor user-namespace
policy, so this deployment uses regular DinD instead of weakening that host-wide
policy. Only trusted workflows may target this runner.

DinD 显式使用 `--mtu=1450`，与 k3s Pod 的 `eth0` 一致。不要在未验证节点 Pod
MTU 的情况下删除或修改它：DinD 默认创建 MTU 1500 的 Actions bridge，容器虽然
能够解析 GitHub、甚至建立 TCP 连接，但较大的 TLS 数据包会在嵌套网络路径中丢失，
表现为 `github.com` / `api.github.com` 超时。Pod 网络和 `--network host` 正常不代表
job bridge 正常。

The runner is registered at instance scope so it is available to every repository
on this Gitea instance. Repository permissions and protected-branch review are
therefore the security boundary; do not enable Actions for untrusted repositories.

The runner registration token is authoritative in OpenBao at
`kv/k8s/gitea-runner`. External Secrets Operator projects its `token` property to
the `gitea-runner-token` Secret. Never put the token in this directory or a Helm
command line.

## Flux 接管状态

该 release 最初通过下述 review-first 流程手动 bootstrap。下一个 GitOps 阶段将
使用 Flux `HelmRelease` 接管它，并首先固定现有 chart `0.1.1`，不在接管 PR 中升级。

迁移前审计发现：Helm 保存的 user-supplied values 和 release manifest 仍描述失败的
rootless DinD 尝试，但 live StatefulSet 与本目录 `values.yaml` 都已经使用 regular
DinD。首次 reconcile 的验收条件是修正 Helm 存储状态，同时 live Pod spec、PVC
identity、runner capacity 和在线状态保持不变。接管稳定后再用独立 PR 升级 chart。

接管分两阶段：第一阶段提交 `suspend: true` 的 HelmRelease、HelmRepository 和由
`values.yaml` 生成的 ConfigMap。Flux 只登记这些对象，不执行 Helm action。合并后
检查 HelmRepository Ready，并用固定 chart 重复比较期望清单与 live StatefulSet；
第二阶段解除 suspend。第一阶段已经确认 source Ready、完整 chart render 与 live
资源零差异，且登记过程中现有 runner 没有 rollout。失败重试使用
`RetryOnFailure`，不会用 stored rootless release 做 rollback。

## 历史 review-first bootstrap

这是 Flux 安装前执行过的一次性手动部署流程，保留用于恢复和审计：

1. Merge the reviewed PR.
2. As a Gitea site administrator, create an instance-scoped runner registration
   token under **Site Administration → Actions → Runners**.
3. Store it as the `token` property at `kv/k8s/gitea-runner` without exposing it
   in shell history:

   ```bash
   read -rsp 'Runner token: ' runner_token
   printf '%s' "$runner_token" | bao kv put kv/k8s/gitea-runner token=-
   unset runner_token
   ```

4. From the updated `main`, create the namespace and ExternalSecret, then wait
   for `SecretSynced=True`:

   ```bash
   KUBECONFIG="$HOME/.kube/config" k3s kubectl apply \
     -f platform/gitea-runner/namespace.yaml
   KUBECONFIG="$HOME/.kube/config" k3s kubectl apply \
     -f platform/gitea-runner/external-secret.yaml
   KUBECONFIG="$HOME/.kube/config" k3s kubectl wait \
     --namespace gitea-actions \
     --for=condition=Ready externalsecret/gitea-runner-token \
     --timeout=60s
   ```

5. Install chart `actions` version `0.1.1` from
   `https://dl.gitea.com/charts/` with this `values.yaml`:

   ```bash
   helm repo add gitea-charts https://dl.gitea.com/charts/
   helm repo update gitea-charts
   helm upgrade --install gitea-actions gitea-charts/actions \
     --namespace gitea-actions \
     --version 0.1.1 \
     --values platform/gitea-runner/values.yaml \
     --wait --timeout 10m
   ```

6. Confirm the runner is online, then re-run the queued lint workflow.

Do not deploy from an unmerged feature branch. Do not use `--set` for the token.

The 1 GiB PVC preserves `.runner` identity. Docker image layers are ephemeral;
the Pod has a 20 GiB ephemeral-storage limit. Terraform apply jobs must use a
workflow concurrency group because runner capacity does not serialize access to
a shared state.
