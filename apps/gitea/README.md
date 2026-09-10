# Gitea

Gitea 使用外部 CloudNativePG 数据库和现有 `gitea-shared-storage` RWO PVC，入口由
Envoy Gateway HTTPRoute 提供。Helm chart 自带的无 class Ingress 暂时保留以确保
首次接管零变化；清理该 Ingress 与升级 chart 必须使用后续独立 PR。

## Flux 接管

初始接管 release 是 `gitea-12.5.3`（Gitea `1.25.5`）。接管分为两个 PR：第一阶段创建
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

当前 release 是 chart `12.7.0` / Gitea `1.27.3-rootless`。两次跨 minor migration、
API、OIDC、Git/Flux 和 runner 均已验证。第二跳按明确决定跳过了新的 1.26.4 停机
一致回滚点；现有 1.25.5 本地备份没有 OCI 或异机副本，因此只作为会丢失后续状态的
灾难恢复点。

## 后续升级默认策略

已连续验证两次 Flux 驱动的跨 minor Recreate upgrade，后续常规 patch/minor 升级
不再默认执行长时间观察、临时 branch push/delete、重复 CI、逐条 migration 日志审计
或每个 minor 的停机备份。默认只需要：

1. 固定 chart 和实际 `image.tag`，阅读与本配置相关的 breaking/security notes；
2. Helm/Kustomize render 通过 review；
3. 合并后确认 HelmRelease `UpgradeSucceeded`、Pod Ready 且没有 CrashLoop；
4. API 返回目标版本，并简单确认 OIDC 登录和一次正常 Git 操作。

只有变更数据库后端或存储布局、rootless 模式、PVC identity、部署策略、重大 chart
结构，或者 release notes 指出相关 breaking migration 时，才恢复停机一致备份、分阶段
suspend、详细日志审计和扩展验收。出现启动失败或 migration error 时也立即升级为完整
故障流程。
