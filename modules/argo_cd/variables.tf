variable "enable_django_application" {
  description = "Керувати Django Application окремо від встановлення Argo CD"
  type        = bool
}

variable "gitops_branch" {
  description = "Гілка HW-05 для автоматичної синхронізації"
  type        = string
}
