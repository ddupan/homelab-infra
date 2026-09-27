# 独立 Ayatori 控制面接入材料

按维护者决定，本目录仅备齐声明，不应用到现有 k3s，不部署 Ayatori。
来源合同为 Ayatori main `f4deb98` 的 Instance API 与 manager flags。

`instances.yaml` 注册 prod/dev 两个 cluster-scoped Instance。`admin-credentials.yaml`
将专用 Bao 路径的 username/password 同步为管理 Secret，不引用含 superuser 密码的实例秘密。
`ca.crt` 是公开中央 CA；`kustomization.yaml` 生成 `homelab-postgresql-ca` ConfigMap。

独立控制面就绪后，由其部署流程完成：

1. 安装 Ayatori CRD 和 ESO，创建 controller namespace（当前预设 `ayatori-system`）。
2. 创建 namespaced `homelab-postgresql-admin` SecretStore，使用该控制面的专用身份访问
   `https://bao.ad.ddupan.top:8200`、KV v2 mount `kv`；权限限于 `eso-policy.hcl`，不复用部署身份。
   auth mount/role 和集群信任绑定须根据真实控制面配置，故此处不虚构可直接应用的 Store。
3. 挂载 `homelab-postgresql-ca` 的 `ca.crt`，设置 manager
   `--database-secret-namespace=ayatori-system` 与 `--database-root-cert=<挂载路径>/ca.crt`。
   namespace 有变更时同步修改 kustomization、SecretStore 和 manager 参数。
4. 渲染并审查 `kubectl kustomize <本目录>`，确认目标 kubecontext 为独立控制面后应用。
5. 等待两个 ExternalSecret 同步和两个 Instance Ready；不要将本文 SQL/TLS 验证当作 controller Ready。

首次独立管理凭据由 `ansible/ayatori-credentials.yml` CAS=0 创建；重复执行只核对已有值，
不自动轮换密码。控制器完整 Database/Tenant 供应链路仍按 Ayatori 自身实施与验收。
