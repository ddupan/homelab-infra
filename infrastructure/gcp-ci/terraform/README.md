# GCP CI 执行环境

`gitea-dynamic-runner` 云端池的 GCP 资源：GKE Autopilot 集群，以及 Actions cache 用的 GCS bucket。
只放不需要 Docker、也不访问内网的 job。

已接入 CI（`TF_ROOTS`），合并即 apply。CI 没有服务账号密钥：`.gitea/scripts/tf.py` 用 SPIRE JWT-SVID
（`aud=gcp`）经 Workload Identity Federation 以 `terraform-ci` 运行（`federation.tf`）。

项目、API、联邦和集群都由这个 root 创建。第一次必须用 `gcloud auth application-default login` 在本地 apply，
因为联邦身份还不存在。组织级授权在 `../../gcp-org/terraform`，只能本地运行。

区域按价格选（见 `variables.tf`），赠金 2027-02-08 到期，到期前要升级付费账号，否则资源会被关停。

`google_storage_hmac_key` 的 secret 会明文进 state，和 `apps/e5renew/terraform` 的 client secret 一样，
靠 tfstate bucket 的访问控制保护。
