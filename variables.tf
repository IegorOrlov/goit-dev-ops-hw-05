variable "bucket_name" {
  description = "Глобально унікальна назва S3-бакета для Terraform state"
  type        = string
}

variable "cluster_name" {
  description = "Назва навчального EKS cluster"
  type        = string
  default     = "lesson-7-eks"
}

variable "admin_principal_arn" {
  description = "Постійний IAM user або role ARN для EKS admin access та ECR push"
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", var.admin_principal_arn))
    error_message = "Потрібний IAM user/role ARN, включно з path за наявності. STS session ARN не підтримується."
  }
}

variable "public_access_cidrs" {
  description = "Публічні IPv4 CIDR адміністратора для доступу до EKS API"
  type        = list(string)
  validation {
    condition     = length(var.public_access_cidrs) > 0 && alltrue([for cidr in var.public_access_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"])
    error_message = "Вкажіть IPv4 CIDR адміністратора, наприклад поточну адресу з /32."
  }
}

variable "enable_jenkins" {
  description = "Встановити Jenkins після підготовки EKS, nodes та EBS CSI"
  type        = bool
  default     = false
}
