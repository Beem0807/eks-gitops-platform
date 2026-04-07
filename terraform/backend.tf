terraform {
  backend "s3" {
    bucket       = "nabeemdev-eks-terraform-state-ap-south-1"
    key          = "eks-gitops-platform/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
  }
}