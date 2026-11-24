variable "cluster_name" {
  description = "Назва EKS cluster та префікс IAM resources"
  type        = string
}

variable "vpc_id" {
  description = "ID VPC поточного Terraform root"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs для control plane та node group"
  type        = list(string)
}

variable "admin_principal_arn" {
  description = "IAM user або role ARN адміністратора Kubernetes"
  type        = string
}

variable "public_access_cidrs" {
  description = "Дозволені IPv4 CIDR для public EKS API"
  type        = list(string)
}
