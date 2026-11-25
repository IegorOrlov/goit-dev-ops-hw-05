locals {
  namespace             = "jenkins"
  agent_service_account = "jenkins-agent"
}

resource "aws_iam_role" "agent" {
  name                 = "${var.cluster_name}-jenkins-agent"
  permissions_boundary = var.agent_ecr_policy_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${trimprefix(var.oidc_provider_url, "https://")}:aud" = "sts.amazonaws.com"
          "${trimprefix(var.oidc_provider_url, "https://")}:sub" = "system:serviceaccount:${local.namespace}:${local.agent_service_account}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "agent_ecr" {
  role       = aws_iam_role.agent.name
  policy_arn = var.agent_ecr_policy_arn
}

resource "helm_release" "jenkins" {
  name             = "jenkins"
  namespace        = local.namespace
  create_namespace = true
  repository       = "https://charts.jenkins.io"
  chart            = "jenkins"
  version          = "5.13.3"
  atomic           = true
  timeout          = 900

  values = [
    file("${path.module}/values.yaml"),
    yamlencode({
      agent = {
        envVars = [{
          name  = "ECR_REPOSITORY_URL"
          value = var.ecr_repository_url
        }]
      }
      serviceAccountAgent = {
        name = local.agent_service_account
        annotations = {
          "eks.amazonaws.com/role-arn"               = aws_iam_role.agent.arn
          "eks.amazonaws.com/sts-regional-endpoints" = "true"
        }
      }
    })
  ]

  depends_on = [aws_iam_role_policy_attachment.agent_ecr]
}
