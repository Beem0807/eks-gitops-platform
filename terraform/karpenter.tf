module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  namespace       = "karpenter"
  service_account = "karpenter"

  create_node_iam_role = true
  node_iam_role_name   = "${var.cluster_name}-karpenter-node"

  create_access_entry = true

  enable_irsa              = true
  irsa_oidc_provider_arn   = module.eks.oidc_provider_arn

  create_pod_identity_association = false

  enable_spot_termination = true
  queue_name              = "${var.cluster_name}-karpenter-interruption"

  tags = merge(
    var.tags,
    {
      "karpenter.sh/discovery" = var.cluster_name
    }
  )
}