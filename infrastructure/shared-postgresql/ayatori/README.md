# 独立 Ayatori 控制面接入材料

本目录仅交付数据库侧声明，不部署或修改 Ayatori 控制面，也不应用到现有 k3s。
Instance 字段及 manager 参数已按 Ayatori main `6b2808c` 核对。

环境隔离与作用域修正由 [PR #167](https://git.ddupan.top/panxiao81/homelab-infra/pulls/167) 提供，
尚待合并；以下目录布局适用于该 PR 分支或合并后的版本。旧聚合入口会同时带出两套管理凭据，
且全局 namespace 会污染 cluster-scoped Instance，不应继续作为接入入口。

## 按环境交付

| 目标 | 渲染入口 | Instance | SecretStore | Bao 只读路径 |
|---|---|---|---|---|
| Dev | `ayatori/dev` | `homelab-dev` | `homelab-postgresql-dev-admin` | `kv/data/infra/postgresql/ayatori/dev` |
| Prod | `ayatori/prod` | `homelab-prod` | `homelab-postgresql-prod-admin` | `kv/data/infra/postgresql/ayatori/prod` |

每个入口只包含一个 cluster-scoped Instance、一个 ExternalSecret 和公开 CA ConfigMap。
仅 ExternalSecret 和 ConfigMap 使用 `ayatori-system` namespace；Instance 不含 namespace。
两个 `eso-policy.hcl` 各自只允许读取本环境管理路径；不要把两个 policy 同时绑定给 Dev 身份。
这些是待绑定策略，不代表 Bao 现场身份已经建立环境隔离。

根 `ayatori/` 入口只渲染公开 CA，不注册实例或同步凭据。`common/ca.crt` 为唯一 CA 文件，
原 `ayatori/ca.crt` 保留相对链接，以兼容现有 SQL/TLS 验证路径。

```bash
kubectl kustomize infrastructure/shared-postgresql/ayatori/dev
kubectl kustomize infrastructure/shared-postgresql/ayatori/prod
```

渲染是离线检查，不会应用资源。不要将两个结果合并后交给 Dev 控制面。
管理 Secret 只含专用账号 username/password，不引用含 superuser 密码的原始实例秘密。

## 交给独立控制面部署流程的依赖

1. 安装对应版本的 Ayatori CRD 和 ESO，准备 controller namespace。
2. 在 `ayatori-system` 创建本环境对应的 namespaced SecretStore，访问
   `https://bao.ad.ddupan.top:8200`、KV v2 mount `kv`。其专用 ESO 身份仅绑定本环境
   `eso-policy.hcl`；不能复用部署身份或跨环境账号。auth mount/role 与真实控制面信任绑定
   由控制面部署负责，此目录不虚构可直接应用的 Store。
3. 挂载 `homelab-postgresql-ca` ConfigMap 的 `ca.crt`，设置 manager
   `--database-secret-namespace=ayatori-system` 和 `--database-root-cert=<挂载路径>/ca.crt`。
   namespace 变化时，只调整 namespaced 资源、Store 与 manager 参数，不给 Instance 加 namespace。
4. 由控制面部署流程确认目标 kubecontext 后应用本环境声明。
5. 验证本环境 ExternalSecret 已同步，再等待对应 Instance Ready；SQL/TLS 或离线渲染通过
   都不等于 controller Ready。完整 Database/Tenant 供应链路按 Ayatori 自身实现验收。

首次专用管理凭据由 `ansible/ayatori-credentials.yml` CAS=0 创建；重复执行核对已有值，
不自动轮换密码。此次声明拆分不改变数据库账号、密码或现有 Bao 数据。

## 验证

```bash
python3 -m unittest discover -s infrastructure/shared-postgresql/tests -p 'test_*.py' -v
```

2026-09-27：5 项本地测试通过，包括渲染后的环境隔离、Instance 作用域、Secret 引用及
最小只读策略；两份 Instance 通过 Ayatori `6b2808c` CRD 的 JSON schema 校验。
该离线 schema 检查不执行 Kubernetes CEL；本轮未安装 CRD、创建 SecretStore、应用资源或验证 Instance Ready。
