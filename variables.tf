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

variable "enable_argo_cd" {
  description = "Встановити Argo CD після підготовки EKS"
  type        = bool
  default     = false
}

variable "enable_django_application" {
  description = "Створити Application після публікації першого образу Jenkins і оновлення values.yaml у Git"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_django_application || var.enable_argo_cd
    error_message = "Для Django Application встановіть enable_argo_cd=true."
  }
}

variable "gitops_branch" {
  description = "Цільова гілка HW-05, що має збігатися з GITOPS_BRANCH у Jenkinsfile"
  type        = string
  default     = "lesson-8-9"
}
