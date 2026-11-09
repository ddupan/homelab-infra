variable "project_id" {
  description = "Project that hosts the billing export dataset; created by ../../gcp-ci/terraform."
  type        = string
  default     = "ddupan-ci"
}

variable "developer_subject" {
  description = "SPIFFE ID allowed to run ad-hoc billing queries; already accepted by the pool's spire provider."
  type        = string
  default     = "spiffe://ddupan.top/dev/panxiao81"
}

variable "collector_subject" {
  description = "SPIFFE ID of the cloud-cost CronJob in platform/observability."
  type        = string
  default     = "spiffe://ddupan.top/ns/monitoring/sa/cloud-cost"
}
