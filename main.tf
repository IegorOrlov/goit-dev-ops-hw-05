# Підключаємо модуль для S3 та DynamoDB
module "s3_backend" {
  source      = "./modules/s3-backend" # Шлях до модуля
  bucket_name = var.bucket_name        # Унікальне ім'я S3-бакета
  table_name  = "terraform-locks"      # Ім'я DynamoDB
}

# Підключаємо модуль для VPC
module "vpc" {
  source             = "./modules/vpc"
  vpc_cidr_block     = "10.0.0.0/16"
  public_subnets     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets    = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  availability_zones = ["us-west-2a", "us-west-2b", "us-west-2c"]
  vpc_name           = "vpc"
}

# Підключаємо модуль для ECR
module "ecr" {
  source                = "./modules/ecr"
  ecr_name              = "lesson-5-ecr"
  scan_on_push          = true
  allowed_principal_arn = var.admin_principal_arn
}

module "eks" {
  source              = "./modules/eks"
  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnets
  admin_principal_arn = var.admin_principal_arn
  public_access_cidrs = var.public_access_cidrs
  depends_on          = [module.vpc]
}

module "jenkins" {
  count                = var.enable_jenkins ? 1 : 0
  source               = "./modules/jenkins"
  cluster_name         = module.eks.cluster_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  agent_ecr_policy_arn = "arn:aws:iam::${module.eks.account_id}:policy/${module.eks.cluster_name}-jenkins-agent-ecr"
  ecr_repository_url   = module.ecr.repository_url

  depends_on = [module.eks, module.ecr]
}
