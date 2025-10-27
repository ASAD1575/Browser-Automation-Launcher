variable "log_group_name" {
  description = "CloudWatch Logs log group name"
  type        = string
  default     = "/prod/app"
}

variable "retention_in_days" {
  description = "Retention for the log group"
  type        = number
  default     = 30
}

variable "cw_kms_key_arn" {
  description = "Optional KMS CMK for log group encryption"
  type        = string
  default     = null
}

variable "cwagent_param_name" {
  description = "SSM parameter path for the CW agent config (string parameter)"
  type        = string
  default     = "/prod/cwagent/windows"
}

variable "cwagent_config_json" {
  description = "The CloudWatch Agent config JSON payload"
  type        = string
}
