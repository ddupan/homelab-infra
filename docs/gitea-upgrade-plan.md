# Gitea 1.25.5 → 1.27.3 升级计划

## 决策

现有 release 为 chart `12.5.3` / Gitea `1.25.5`，已经由 Flux HelmRelease 接管。
升级分两个独立阶段执行，不跨过中间 minor：

1. chart `12.6.0`，显式设置 `image.tag: 1.26.4`；
2. chart `12.7.0`，显式设置 `image.tag: 1.27.3`。

chart 当前默认 appVersion 分别只是 `1.26.1` 和 `1.27.0`，因此不能依赖默认镜像。
官方 `1.26.4` 修复了 1.26.3 的代码页回归并包含安全修复；`1.27.3` 又修复了
Actions fork PR 审批绕过等安全问题。两个 rootless 镜像标签都已经在官方 registry
验证存在。Gitea Runner `2.3.0` 已高于 1.27 推荐的 `2.0.0`，无需与服务端同时升级。

参考：

- [Gitea 升级说明](https://docs.gitea.com/installation/upgrade-from-gitea/)
- [Gitea 备份一致性说明](https://docs.gitea.com/1.26/administration/backup-and-restore/)
- [Gitea 1.26.4 发布说明](https://blog.gitea.com/release-of-1.26.3-and-1.26.4/)
- [Gitea 1.27.0 与 Runner 兼容说明](https://blog.gitea.com/release-of-1.27.0/)
- [Gitea 1.27.3 发布说明](https://blog.gitea.com/release-of-1.27.3/)

## 当前风险边界

- Gitea 使用外部单实例 CNPG；`gitea` 数据库约 19 MB，CNPG 没有配置连续备份，
  `firstRecoverabilityPoint` 为空。
- `/data` 使用 `local-path` RWO PVC，实际数据约 6.2 MB；集群没有
  VolumeSnapshotClass，因此不能把 CSI snapshot 当成回滚点。
- Gitea 是 Flux GitRepository 的上游。Gitea 停机时已应用的资源继续运行，但不能
  依靠新的 Git commit 解救失败的 Gitea。
- 跨 minor 启动会执行数据库 migration。官方明确说明升级后的数据库不能由旧 minor
  安全使用；回退必须同时恢复数据库和 `/data`。
- `gitea-oidc-secret` 仍是手工 Secret。本次只继续引用它，不与版本升级一起迁移。

## 已完成的静态检查

- 使用现有 `gitea-values.yaml` 渲染三个 chart，并从比较中排除 Secret 与 Helm test
  hook；`12.5.3 → 12.6.0` 的业务资源变化只有 chart/app 标签和四处 Gitea 镜像。
- `12.6.0 → 12.7.0` 除同类版本变化外，只包含 Service template 文件重命名、字段
  排版变化和 test hook 参数排版，没有新增或删除 live 业务对象。
- `docker.gitea.com/gitea:1.26.4-rootless` 与
  `docker.gitea.com/gitea:1.27.3-rootless` 的 multi-arch manifests 均存在。
- 当前 Gitea 日志没有 deprecation、warning 或 error；HTTPRoute、内部 API、统一域名
  API 与 Flux GitRepository 均 Ready。

## 每个 minor 的执行单元

两个阶段各自重复以下流程。1.26 验收完成前不得创建 1.27 的执行 PR。

### 1. 预拉取与 review

1. 在 HelmRelease 中显式设置目标 `image.tag`，同时把 chart 固定到该阶段目标版本，
   并重新执行 Helm/Kustomize render。目标 chart、镜像与 `suspend: true` 必须在同一
   HelmRelease 对象内原子提交；不得同时修改会触发 watch 的 values ConfigMap。
2. 在节点预拉取目标 rootless 镜像，避免维护窗口受 WAN 波动影响。
3. 创建 **保持 `spec.suspend: true`** 的准备 PR；合并并等 Flux 同步。此时 Git 只记录
   目标版本，不执行 Helm action。
4. 从该准备 commit 创建只删除 `suspend` 的激活 PR，提前 push 到 Gitea，但暂不合并。

### 2. 建立一致回滚点

Gitea 官方要求停机备份才能保证数据库、仓库、LFS、附件和 metadata 一致。本环境
数据量很小，因此接受一个短维护窗口，不使用在线 `gitea dump` 冒充一致备份。

1. 确认 HelmRelease 已 suspended，记录 Deployment、ReplicaSet、Pod UID、Helm
   revision、数据库大小和 PVC 路径。
2. 手工将 Gitea Deployment scale 到 0 并等待 Pod 消失。此时 runner 会暂时无法上报，
   Flux source 会暂时 NotReady，但现有工作负载不受影响。
3. 对 CNPG 的 `gitea` 数据库执行 custom-format `pg_dump`；对 PVC host path 创建保留
   owner/xattr 的 tar archive。两个文件写入节点上新建的、权限为 0700 的时间戳目录。
4. 生成 SHA-256，执行 `pg_restore --list` 和 `tar --list`，确认两份文件可读。
5. 用个人 GPG 公钥加密后复制一份到 OCI Object Storage（或另一台物理机）；未验证
   第二份副本前不得升级。
6. 将 Deployment scale 回 1，确认仍以旧版本启动，并验证 API、OIDC 登录、clone、
   push 和 Actions runner online。

手工 scale 只用于取得一致备份；HelmRelease 此时 suspended，不会发生 drift repair。
备份结束后服务恢复，后续激活 PR 仍通过正常 Gitea review/merge，不需要在 Gitea 停机
时修改 Git 或 live HelmRelease。

### 3. 由 Flux 升级

1. review 并合并已经 push 的激活 PR；它唯一的行为变化应是删除 `suspend: true`。
2. 不手工 reconcile，观察 Flux 正常发现 revision、Helm upgrade 和 Gitea migration。
3. `Recreate` strategy 会先终止旧 Pod 再启动新 Pod，避免 RWO PVC 与 leveldb queue
   lock 导致双 Pod deadlock。
4. 若 15 分钟内 HelmRelease 未 Ready，停止自动重试并进入回滚判断，不连续修改
   values 猜测修复。

### 4. 每阶段验收

- HelmRelease `Ready=True`、`UpgradeSucceeded`，Helm revision 只增加一次；
- Deployment 和 Pod 使用目标 rootless 镜像，PVC UID/volume name 不变；
- Gitea `/api/v1/version` 从 Pod 内和 `https://git.ddupan.top` 返回目标版本；
- Authelia OIDC 管理员登录与 break-glass 本地管理员登录均有效；
- 对现有仓库完成 HTTPS clone、创建临时 branch、push、删除临时 branch；
- 当前仓库 Actions workflow 能入队并由 runner `2.3.0` 完成；
- Flux GitRepository 恢复 Ready 并能拉取升级 revision；
- package registry、Terraform package/state API（启用后）与附件/LFS 按实际使用情况抽查；
- 日志中没有 migration failure、panic、持续数据库错误或配置弃用警告；
- 稳定观察至少 15 分钟，再把该阶段记录为完成。

## 回滚

patch 版本原则上保持数据库结构兼容；本计划的两个步骤都是跨 minor，不能仅回退镜像。
若 migration 后目标版本无法健康启动：

1. 暂停 `Kustomization/gitea` 和 `HelmRelease/gitea`，停止 Gitea Deployment；
2. 保存失败现场的 Pod logs、Helm status 与 migration error；
3. 删除并从同一阶段备份恢复 `gitea` 数据库；
4. 清空并从配套 tar 恢复原 PVC 内容，保持 owner、mode 和 xattr；
5. 将 live HelmRelease 临时恢复到上一阶段 chart/image，并启动验证；
6. Gitea 恢复后，通过 PR 把 Git desired state 恢复到上一阶段，再恢复 Flux
   Kustomization。不得让 Flux 在数据库尚未恢复时自动拉回新版本。

数据库 dump 与 PVC archive 是一个不可拆分的回滚点；禁止混用不同时间或不同阶段的
两份备份。

## 1.26.4 阶段执行记录

- 目标 `1.26.4-rootless` 镜像已经预拉取到 k3s 节点；
- Gitea 停写后生成了 custom-format PostgreSQL dump 与保留 owner/ACL/xattr 的 PVC
  tar，两者分别通过 `pg_restore --list`、`tar --list` 和 SHA-256 校验；
- 本地回滚点位于
  `/var/backups/homelab/gitea/20260910T060400Z-1.25.5/`，权限为 0700；其中另有使用
  个人 GPG 公钥加密并通过 packet 检查的 bundle；
- 操作者明确选择不上传 OCI，因此本阶段接受只有节点本地副本的风险例外；
- 备份后旧版 `1.25.5` 已恢复，Pod 内与统一域名 API、Gitea API 和 Flux Git source
  均验证正常。

激活后 Helm revision 16 以 chart `12.6.0` 成功部署
`docker.gitea.com/gitea:1.26.4-rootless`。Migration 323–330 完成；Pod 内和统一域名
API、临时 branch push/delete、Flux source，以及 main/smoke 的 YAML、Ansible、
Terraform CI 均通过。Pod 在约 15 分钟观察期内保持 Running、零重启；Authelia OIDC
配置 init 同步及浏览器交互式管理员登录也已确认成功。

## 1.27.3 阶段准备状态

- 目标 `1.27.3-rootless` 镜像已经预拉取到 k3s 节点；
- Git desired state 固定为 chart `12.7.0` 与显式 image `1.27.3`，并重新设置
  `suspend: true`；
- 合并准备状态后必须从已经迁移的 1.26.4 数据重新建立一组数据库/PVC 回滚点，禁止
  复用 1.25.5 备份作为 1.27 阶段的直接回滚点。

执行时操作者明确选择跳过上述 1.26.4 备份门槛并继续激活。该风险例外意味着 1.27
migration 后若失败，不能无损回到 1.26.4；现有本地 1.25.5 备份只可用于接受丢失
第一跳之后状态的灾难恢复。目标 1.27.3 镜像已预拉取，其余准备检查均已通过。

## 后续但不并入升级

- 将 `gitea-oidc-secret` 等剩余手工 Secret 迁入 OpenBao/ESO；
- Gitea 1.27 稳定后验证最小权限 Actions job token，再实现无集群凭据的 PR render
  diff/summary；live `kubectl diff` 仍使用独立、受信任且限权的执行路径；
- 单独评估关闭 chart 生成但无人处理的 Ingress；
- 为 CNPG 和 Gitea `/data` 建立周期性、异机可恢复备份，替代升级前一次性备份。
