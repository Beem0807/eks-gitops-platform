module "vpc" {
  source = "../modules/vpc"

  vpc_name        = var.vpc_name
  vpc_cidr        = var.vpc_cidr
  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
}

module "eks" {
  source = "../modules/eks"

  cluster_name      = var.cluster_name
  aws_region        = var.aws_region
  vpc_id            = module.vpc.vpc_id
  private_subnets   = module.vpc.private_subnets
  instance_type     = var.instance_type
  node_desired_size = var.node_desired_size
  node_min_size     = var.node_min_size
  node_max_size     = var.node_max_size
}

resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  }

  depends_on = [module.eks]
}

# EKS marks the cluster Active before its API server DNS record has fully
# propagated. Without this wait the kubernetes/helm providers fail with
# "no such host" immediately after the kubeconfig is updated.
resource "time_sleep" "wait_for_dns" {
  create_duration = "60s"
  depends_on      = [null_resource.update_kubeconfig]
}

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_namespace
  }

  depends_on = [time_sleep.wait_for_dns]
}

resource "helm_release" "simple_time_service" {
  name      = "simple-time-service"
  namespace = kubernetes_namespace.app.metadata[0].name
  chart     = "../../charts/simple-time-service"

  depends_on = [kubernetes_namespace.app]

  values = [
    yamlencode({
      image = {
        repository = var.app_image_repository
        tag        = var.app_image_tag
        pullPolicy = "IfNotPresent"
      }

      service = {
        type       = "LoadBalancer"
        port       = 80
        targetPort = 8080
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        }
      }

      hpa = {
        enabled = false
      }

      serviceMonitor = {
        enabled = false
      }
    })
  ]
}

data "kubernetes_service_v1" "simple_time_service" {
  metadata {
    name      = "simple-time-service"
    namespace = var.app_namespace
  }

  depends_on = [helm_release.simple_time_service]
}