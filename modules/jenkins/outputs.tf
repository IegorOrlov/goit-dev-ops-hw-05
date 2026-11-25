output "admin_password_command" {
  description = "Команда для отримання початкового пароля Jenkins через kubectl"
  value       = "kubectl --context \"${var.cluster_name}\" -n \"${helm_release.jenkins.namespace}\" get secret \"${helm_release.jenkins.name}\" -o jsonpath='{.data.jenkins-admin-password}' | base64 -d"
}
