# Contour 退役清理

Envoy Gateway 已经承载全部现用 `Gateway` 和 `HTTPRoute`。Contour 在集群中仅剩
gateway provisioner、RBAC、旧 `GatewayClass` 和没有实例的 CRD，不再承载流量。

清理必须在本变更合并后进行，顺序如下：

1. 应用更新后的 `platform/cert-manager/clusterissuer-bao-acme.yaml`，把 OpenBao
   HTTP-01 solver 改到 `envoy-gateway-system/eg` 的 `http` listener；
2. 确认 `Gateway/eg` 为 `Programmed=True`，所有现用 `HTTPRoute` 保持正常；
3. 删除 `GatewayClass/contour`；
4. 删除 `projectcontour` namespace；
5. 删除名称包含 `contour` 的遗留 ClusterRole/ClusterRoleBinding；
6. 在确认所有 Contour 自定义资源均为空后，删除 `projectcontour.io` 的五个 CRD；
7. 复查 Envoy Gateway、证书、DNS 和现用入口。

这些对象是 Flux 启用前留下的孤立资源，首次清理由本机 `kubectl` 完成。Flux 的
root Kustomization 初始保持 `prune: false`，不会借 bootstrap 顺带删除 brownfield
资源。

