variable "project_id" {
  description = "GCP project that hosts CI executors."
  type        = string
  default     = "ddupan-ci"
}

variable "org_id" {
  type    = string
  default = "74885522592"
}

variable "billing_account" {
  type    = string
  default = "01FFF4-530462-8FC932"
}

# 按价格选，赠金用完后也要继续跑：美国区是 Autopilot 最便宜的一档（大阪贵约 29%，2026-11），
# Cloud Run 的免费额度也按 us-central1 计价。CI 对延迟不敏感。
variable "region" {
  description = "Region of the Autopilot cluster and the cache bucket; keep them together to avoid inter-region transfer."
  type        = string
  default     = "us-central1"
}
