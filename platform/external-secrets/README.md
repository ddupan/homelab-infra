# External Secrets Operator

External Secrets Operator（ESO）把 OpenBao `kv/k8s/*` 下的值投影为 Kubernetes
Secret。`ClusterSecretStore/openbao` 使用 `external-secrets` ServiceAccount 的短期
JWT 登录 OpenBao，不在 Git 中保存长期凭据。

## Flux 接管

现有 release 是 2026-07-28 手工安装的 chart `external-secrets` `2.8.0`，Helm
revision 1。接管前审计确认：本目录 `values.yaml` 与 Helm stored user values 一致；
用固定 chart 生成的 33,528 行 manifest 与 stored manifest 只有末尾空行差异。

接管分两阶段。第一阶段以 `suspend: true` 登记 HelmRepository、values ConfigMap 与
HelmRelease；合并后已确认 source Ready、release 仍为 revision 1，三个 Pod UID 保持
不变且零重启。第二阶段只移除 `suspend`，允许 Flux 修正 Helm stored ownership 并
启用 drift detection；chart、values 和子 Kustomization 的 `prune: false` 均不变。

`clustersecretstore.yaml` 和 `externalsecrets.yaml` 是现有 secret delivery intent，
本阶段故意不把它们加入该 Kustomization，避免在 Helm release 接管时同时扩大 Flux
ownership。Helm 接管稳定后再单独审计、纳管这些对象。
