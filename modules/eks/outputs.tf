output "cluster_name" {
  description = "Назва EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "kubernetes_version" {
  description = "Обрана minor версія Kubernetes"
  value       = aws_eks_cluster.main.version
}

output "cluster_endpoint" {
  description = "URL Kubernetes API"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Security group EKS control plane та managed nodes"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "load_balancer_controller_role_arn" {
  description = "IRSA role для kube-system/aws-load-balancer-controller"
  value       = aws_iam_role.irsa["load_balancer"].arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role для kube-system/ebs-csi-controller-sa"
  value       = aws_iam_role.irsa["ebs_csi"].arn
}

output "node_group_name" {
  description = "Назва managed node group"
  value       = aws_eks_node_group.main.node_group_name
}
