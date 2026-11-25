output "s3_bucket_name" {
  description = "Назва S3-бакета для стейтів"
  value       = module.s3_backend.s3_bucket_name
}

output "dynamodb_table_name" {
  description = "Назва таблиці DynamoDB для блокування стейтів"
  value       = module.s3_backend.dynamodb_table_name
}

output "s3_bucket_url" {
  description = "Регіональний HTTPS URL S3-бакета"
  value       = module.s3_backend.s3_bucket_url
}

output "vpc_id" {
  description = "ID створеної VPC"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "Список ID публічних підмереж"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "Список ID приватних підмереж"
  value       = module.vpc.private_subnets
}

output "internet_gateway_id" {
  description = "ID Internet Gateway"
  value       = module.vpc.internet_gateway_id
}

output "nat_gateway_id" {
  description = "ID NAT Gateway"
  value       = module.vpc.nat_gateway_id
}

output "ecr_repository_url" {
  description = "URL ECR repository для Docker images"
  value       = module.ecr.repository_url
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "jenkins_admin_password_command" {
  description = "Команда для отримання початкового пароля Jenkins після встановлення"
  value       = one(module.jenkins[*].admin_password_command)
}

output "argocd_admin_password_command" {
  description = "Команда для отримання початкового пароля Argo CD після встановлення"
  value       = one(module.argo_cd[*].admin_password_command)
}

output "kubernetes_version" {
  value = module.eks.kubernetes_version
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "load_balancer_controller_role_arn" {
  value = module.eks.load_balancer_controller_role_arn
}

output "ebs_csi_role_arn" {
  value = module.eks.ebs_csi_role_arn
}

output "node_group_name" {
  value = module.eks.node_group_name
}

output "aws_region" {
  value = "us-west-2"
}

output "ecr_repository_name" {
  value = "lesson-5-ecr"
}
