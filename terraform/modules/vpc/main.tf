terraform {
  required_version = "~> 1.14"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = merge(
    {
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.enable_karpenter_discovery_tags ? {
      "karpenter.sh/discovery" = var.cluster_name
      "subnet-type"            = "private"
    } : {}
  )

  tags = var.tags
}