variable "cluster_name" {
  description = "Назва EKS cluster і префікс IAM role агента"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN IAM OIDC provider кластера"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL IAM OIDC provider для перевірки audience і subject"
  type        = string
}

variable "agent_ecr_policy_arn" {
  description = "ARN адміністраторської ECR policy для agent role та її permissions boundary"
  type        = string
}
