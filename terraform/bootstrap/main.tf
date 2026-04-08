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
# propagated. Poll until the specific cluster endpoint resolves (up to 10 minutes).
# NOTE: we poll module.eks.cluster_endpoint directly (not self.triggers) to
# always check the live endpoint, avoiding stale-trigger false-positives.
resource "null_resource" "wait_for_api" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOF
      ENDPOINT="${module.eks.cluster_endpoint}"
      HOSTNAME=$(echo "$ENDPOINT" | sed 's|https://||' | sed 's|/||g')
      echo "Waiting for EKS API server DNS to propagate (host: $HOSTNAME)..."
      for i in $(seq 1 40); do
        if nslookup "$HOSTNAME" > /dev/null 2>&1; then
          echo "DNS resolved on attempt $i. Sleeping 30s for propagation to stabilise..."
          sleep 30
          echo "Done."
          exit 0
        fi
        echo "Attempt $i/40: DNS not yet resolvable, retrying in 15s..."
        sleep 15
      done
      echo "ERROR: EKS API server did not become DNS-resolvable within 10 minutes" && exit 1
    EOF
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_namespace
  }

  depends_on = [null_resource.wait_for_api]
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

# Wait for the NLB to be provisioned and assigned a hostname before reading it.
# The cloud controller takes 1-3 minutes to create the NLB after the Service is applied.
resource "null_resource" "wait_for_lb" {
  triggers = {
    helm_release = helm_release.simple_time_service.status
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting for NLB hostname to be assigned..."
      for i in $(seq 1 40); do
        HOSTNAME=$(kubectl get svc simple-time-service \
          -n ${var.app_namespace} \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$HOSTNAME" ]; then
          echo "NLB hostname assigned on attempt $i: $HOSTNAME"
          exit 0
        fi
        echo "Attempt $i/40: NLB not ready yet, retrying in 15s..."
        sleep 15
      done
      echo "ERROR: NLB hostname was not assigned within 10 minutes" && exit 1
    EOF
  }

  depends_on = [helm_release.simple_time_service]
}

data "kubernetes_service_v1" "simple_time_service" {
  metadata {
    name      = "simple-time-service"
    namespace = var.app_namespace
  }

  depends_on = [null_resource.wait_for_lb]
}

# Validate the service is healthy by hitting the /health endpoint on the NLB.
resource "null_resource" "validate_health" {
  triggers = {
    helm_release = helm_release.simple_time_service.status
  }

  provisioner "local-exec" {
    command = <<-EOF
      HOSTNAME="${data.kubernetes_service_v1.simple_time_service.status[0].load_balancer[0].ingress[0].hostname}"
      echo "Validating /health endpoint at http://$HOSTNAME/health ..."
      for i in $(seq 1 40); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" --max-time 5 "http://$HOSTNAME/health" 2>/dev/null || true)
        if [ "$HTTP_CODE" = "200" ]; then
          echo "Health check passed on attempt $i (HTTP $HTTP_CODE)"
          exit 0
        fi
        echo "Attempt $i/40: /health returned '$HTTP_CODE', retrying in 15s..."
        sleep 15
      done
      echo "ERROR: /health did not return 200 within 10 minutes" && exit 1
    EOF
  }

  depends_on = [data.kubernetes_service_v1.simple_time_service]
}