module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  enable_irsa = true

  name               = var.cluster_name
  kubernetes_version = "1.34"

  endpoint_public_access       = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnets

  addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        tolerations = [
          {
            key      = "app"
            operator = "Equal"
            value    = "core"
            effect   = "NoSchedule"
          }
        ]
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    eks-pod-identity-agent = {
      most_recent = true
      configuration_values = jsonencode({
        tolerations = [
          {
            key      = "app"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      })
    }
  }

  node_security_group_tags = merge(
    var.tags,
    var.enable_karpenter_discovery_tags ? {
      "karpenter.sh/discovery" = var.cluster_name
    } : {}
  )

  node_security_group_additional_rules = var.enable_nlb_nodeport_rule ? {
    ingress_nlb_nodeports = {
      description = "Allow NLB to reach NodePorts"
      protocol    = "tcp"
      from_port   = 30000
      to_port     = 32767
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  } : {}

  eks_managed_node_groups = {
    default = {
      instance_types = [var.instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      disk_size      = 20

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = var.private_subnets

      labels = {
        app = "core"
      }

      taints = {
        core = {
          key    = "app"
          value  = "core"
          effect = "NO_SCHEDULE"
        }
      }

      update_config = {
        max_unavailable_percentage = 50
      }

      tags = merge(
        var.tags,
        var.add_cluster_autoscaler_tags ? {
          "k8s.io/cluster-autoscaler/enabled"             = "true"
          "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
        } : {}
      )
    }
  }

  tags = var.tags
}