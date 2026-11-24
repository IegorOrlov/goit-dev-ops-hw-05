terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
  }
}

resource "helm_release" "argo_cd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.1"
  atomic           = true
  wait             = true
  timeout          = 900

  values = [file("${path.module}/values.yaml")]
}

resource "helm_release" "django_application" {
  count     = var.enable_django_application ? 1 : 0
  name      = "django-app"
  namespace = helm_release.argo_cd.namespace
  chart     = "${path.module}/charts/django-application"
  wait      = true
  timeout   = 900

  values = [yamlencode({
    source = {
      targetRevision = var.gitops_branch
    }
  })]
}
