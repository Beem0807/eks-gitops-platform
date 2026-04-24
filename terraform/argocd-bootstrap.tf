data "aws_caller_identity" "current" {}

# EKS can report the cluster active before the API endpoint DNS is fully resolvable.
# Wait until the endpoint hostname resolves before applying Kubernetes resources.
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
      echo "ERROR: EKS API server did not become DNS-resolvable within 10 minutes" >&2
      exit 1
    EOF
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [null_resource.wait_for_api]
}

# Split the pinned Argo CD install manifest into individual YAML documents.
data "kubectl_file_documents" "argocd_install" {
  content = file("${path.module}/argocd-install.yaml")
}

resource "kubectl_manifest" "argocd_install" {
  for_each  = data.kubectl_file_documents.argocd_install.manifests
  yaml_body = each.value

  depends_on = [kubernetes_namespace.argocd]
}

# Create a Secret-backed representation of the local cluster so the
# ApplicationSet cluster generator can read labels/annotations.

resource "kubectl_manifest" "argocd_cluster_secret" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "simple-eks-${var.environment}-${var.aws_region}"
      namespace = "argocd"
      labels = {
        "argocd.argoproj.io/secret-type" = "cluster"
        "env"                            = var.environment
        "region"                         = var.aws_region
        "cloud"                          = "aws"
      }
      annotations = {
        "aws-account-id" = data.aws_caller_identity.current.account_id
      }
    }
    type = "Opaque"
    stringData = {
      name   = "in-cluster-local"
      server = "https://kubernetes.default.svc"
      config = jsonencode({
        tlsClientConfig = {
          insecure = false
        }
      })
    }
  })

  depends_on = [kubectl_manifest.argocd_install]
}

resource "kubectl_manifest" "root_app" {
  yaml_body = file("${path.module}/../gitops/bootstrap/root-app.yaml")

  depends_on = [kubectl_manifest.argocd_cluster_secret]
}