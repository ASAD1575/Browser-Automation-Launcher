variable "existing_role_name" {
  description = "Name of the existing IAM role"
  type        = string
}

variable "instance_profile_name" {
  description = "Name of the IAM instance profile (if different from role name). If not specified, uses role name."
  type        = string
  default     = null
}

variable "create_instance_profile_if_missing" {
  description = "If true, create the instance profile if it doesn't exist. If false, only use existing instance profile."
  type        = bool
  default     = true
}