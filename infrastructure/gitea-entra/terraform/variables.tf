variable "admin_upn" {
  description = "唯一被分配到 Gitea 应用的 Entra 用户；其 mail 必须是 Gitea 账号的已激活邮箱之一（自动关联靠它）。"
  type        = string
  default     = "panxiao81@ddupan.top"
}

variable "secret_rotation_days" {
  description = "此后第一次 apply 会签发新 secret。"
  type        = number
  default     = 640
}

variable "secret_lifetime" {
  description = "每个 secret 的有效期；必须比 rotation_days 多出足够的余量，等人来 apply。"
  type        = string
  default     = "17520h" # 730 天：轮换到期后还有 90 天
}
