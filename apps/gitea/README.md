# Gitea

Gitea 使用外部 CloudNativePG 数据库和现有 `gitea-shared-storage` RWO PVC，入口由
Envoy Gateway HTTPRoute 提供。Helm chart 自带的无 class Ingress 暂时保留以确保
首次接管零变化；清理该 Ingress 与升级 chart 必须使用后续独立 PR。

## Flux 接管

现有 release 是 `gitea-12.5.3`（Gitea `1.25.5`）。接管分为两个 PR：第一阶段创建
固定版本且 `suspend: true` 的 HelmRelease，只让 Flux 登记对象；确认 source Ready
并重新验证完整 chart render 后，第二阶段解除 suspend。第一阶段已经确认 source、
子 Kustomization 和 HTTPRoute 均 Ready，Helm revision 与 Gitea Pod 未变化；第二次
live diff 仍只有不常驻的 test hook Pod。子 Kustomization 和集群 root 均保持
`prune: false`。

数据库密码已经由 External Secrets Operator 从 OpenBao 投射到 `gitea-db`。OIDC
client secret 仍是历史手工 Secret `gitea-oidc-secret`，本次接管只引用、不覆盖它；
将剩余 Secret 迁移到 OpenBao 是独立的后续工作。

Gitea 是 Flux GitRepository 的上游。升级或重启期间 Git source 暂时不可用不会删除
已经应用的资源；Gitea 恢复后 Flux 会继续同步。任何会改变 Pod template、数据库迁移
或 PVC identity 的变更都不得与首次接管合并。

跨 minor 的执行顺序、停机一致备份和失败恢复步骤见
[`../../docs/gitea-upgrade-plan.md`](../../docs/gitea-upgrade-plan.md)。
