# GCP CI 执行环境

`gitea-dynamic-runner` 云端池的 GCP 资源：GKE Autopilot 集群，以及 Actions cache 服务（`cache-server.tf`，免费额度的 e2-micro）。
只放不需要 Docker、也不访问内网的 job。

已接入 CI（`TF_ROOTS`），合并即 apply。CI 没有服务账号密钥：`.gitea/scripts/tf.py` 用 SPIRE JWT-SVID
（`aud=gcp`）经 Workload Identity Federation 以 `terraform-ci` 运行（`federation.tf`）。

项目、API、联邦和集群都由这个 root 创建。第一次必须用 `gcloud auth application-default login` 在本地 apply，
因为联邦身份还不存在。组织级授权在 `../../gcp-org/terraform`，只能本地运行。

区域按价格选（见 `variables.tf`），赠金 2027-02-08 到期，到期前要升级付费账号，否则资源会被关停。

`scheduler.tf` 是 homelab 里 cloud-scheduler（`platform/dynamic-runner`）的 GCP 身份，以及集群里
executor Pod 所需的 namespace、ServiceAccount、runner ConfigMap 和 cache Secret（`kubernetes` provider）。

费用：总额、预算告警和账单导出见 `../../gcp-billing`。集群开了 GKE cost allocation，Detailed 导出里带
Pod label，可以按仓库和规格拆实际费用。实时情况看 Grafana 的“CI 云端执行”面板（cloud-scheduler 指标）。

cache-server 的共享密钥（`random_password`）会明文进 state，和 `apps/e5renew/terraform` 的 client secret 一样，
靠 tfstate bucket 的访问控制保护。
