data "aws_caller_identity" "current" {}

locals {
  kubernetes_version = "1.35"
  role_boundary_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-role-boundary"
  irsa_accounts = {
    load_balancer = "system:serviceaccount:kube-system:aws-load-balancer-controller"
    ebs_csi       = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
  }
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.cluster_name}-cluster"
  permissions_boundary = local.role_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = local.kubernetes_version

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  lifecycle {
    postcondition {
      condition     = self.vpc_config[0].vpc_id == var.vpc_id
      error_message = "EKS має бути створений у VPC поточного Terraform root."
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

resource "aws_iam_role" "node" {
  name                 = "${var.cluster_name}-node"
  permissions_boundary = local.role_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonEKS_CNI_Policy"
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# Четвертий t3.small дає місце для Jenkins agent після розгортання Django.
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "demo"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  version         = local.kubernetes_version
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["t3.small"]
  capacity_type   = "ON_DEMAND"
  disk_size       = 20

  scaling_config {
    desired_size = 4
    min_size     = 4
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# IAM отримує certificate chain issuer без додаткового TLS provider.
resource "aws_iam_openid_connect_provider" "main" {
  url            = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "irsa" {
  for_each             = local.irsa_accounts
  name                 = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  permissions_boundary = local.role_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.main.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:sub" = each.value
        }
      }
    }]
  })
}

# Офіційна policy для controller v2.14.1 зберігається поруч із модулем.
resource "aws_iam_policy" "load_balancer" {
  name   = "${var.cluster_name}-load-balancer"
  policy = file("${path.module}/load-balancer-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "load_balancer" {
  role       = aws_iam_role.irsa["load_balancer"].name
  policy_arn = aws_iam_policy.load_balancer.arn
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs_csi"].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}
