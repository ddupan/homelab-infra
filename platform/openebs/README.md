# OpenEBS — 本地 ZFS 存储

OpenEBS umbrella chart 为单节点 k3s 提供 `zfs-localpv` CSI provisioner，并保留
chart 自带的 local PV、Loki、Alloy 与 MinIO 组件。业务 PVC 使用独立声明的
`localpv-zfs-ceph` StorageClass，在宿主机 ZFS pool `data/ceph` 上创建 dataset/zvol。

## 当前版本与引擎

- release：`openebs`，namespace：`openebs`
- chart/app：`4.4.0`
- ZFS LocalPV：启用
- LVM LocalPV、RawFile LocalPV、Mayastor：显式禁用
- bundled Loki SingleBinary：单副本

不要在 chart 升级时顺带启用其他存储引擎。`localpv-zfs-ceph` 当前（2026-11-03）承载
SeaweedFS、VictoriaMetrics、VictoriaLogs、VictoriaTraces、Grafana、Nexus、NATS 与
SPIRE Server 的持久卷；删除 StorageClass 不会删除已有 PV，但误删/重建 chart 资源可能中断
provisioner，因此 brownfield 接管期间保持 `prune: false`。

## Flux 接管状态

现有 Helm release 保存的 user-supplied values 与本目录 `values.yaml` 一致，并已固定
`4.4.0` 完成分阶段 Flux HelmRelease 接管。阶段一确认 source Ready、Helm revision
保持为 3、8 个 OpenEBS Pod UID 未变、10/10 ZFS PV 和集群 20/20 PVC Bound，且
`data/ceph` 下 10 个 volume 未变；随后通过独立 PR 解除暂停。

CRD 在 install/upgrade 时使用 `CreateReplace`，但绝不通过删除 CRD 迁移。接管和升级
是两个独立动作；首次激活不得改变 chart、values、StorageClass 或存储引擎。

## Break-glass 手工恢复

正常变更应提交 Git。Flux 不可用时可暂时执行：

```bash
helm upgrade --install openebs openebs/openebs --version 4.4.0 \
  -n openebs --create-namespace -f platform/openebs/values.yaml
kubectl apply -f platform/openebs/storageclasses.yaml
```

恢复 Flux 后，应以 Git 为准并确认 HelmRelease 没有 drift。

## 验证

```bash
kubectl -n openebs get pods
kubectl get storageclass localpv-zfs-ceph
kubectl get pv | grep localpv-zfs-ceph
kubectl get pvc -A
zfs list -r data/ceph
```

所有既有 PV 必须保持 `Bound`。验证新 provisioner 时只创建单独的临时 PVC，不要修改
或删除业务 PVC，也不要用 `helm uninstall` 验证接管。
