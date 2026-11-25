output "admin_password_command" {
  description = "Команда для отримання початкового пароля Argo CD через kubectl"
  value       = "kubectl --context \"${var.cluster_name}\" -n \"${helm_release.argo_cd.namespace}\" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
