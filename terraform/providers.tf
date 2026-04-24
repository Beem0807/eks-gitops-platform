provider "aws" {
  region = var.aws_region
}

# Read the cluster details from AWS at apply time.
data "aws_eks_cluster" "cluster" {
  name       = var.cluster_name
  depends_on = [module.eks]
}