module "vpc" {
  source = "./modules/vpc"

  vpc_name        = var.vpc_name
  vpc_cidr        = var.vpc_cidr
  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
  tags            = var.tags
}

module "eks" {
  source = "./modules/eks"

  cluster_name    = var.cluster_name
  aws_region      = var.aws_region
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  instance_type     = var.instance_type
  node_desired_size = var.node_desired_size
  node_min_size     = var.node_min_size
  node_max_size     = var.node_max_size
  tags              = var.tags
}