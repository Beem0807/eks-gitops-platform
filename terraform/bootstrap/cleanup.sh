#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TF_DIR="${ROOT_DIR}/terraform"

ARGOCD_NS="argocd"

echo "Running cleanup preflight checks..."

REQUIRED_COMMANDS=(
  terraform
  aws
  kubectl
  helm
  git
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: Terraform directory not found: $TF_DIR"
  exit 1
fi

echo "Preflight checks passed."

cd "$TF_DIR"

echo "Reading Terraform outputs..."

CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null || true)"
AWS_REGION="$(terraform output -raw region 2>/dev/null || true)"

if [[ -n "$CLUSTER_NAME" && -n "$AWS_REGION" ]]; then
  echo "Updating kubeconfig for cluster: $CLUSTER_NAME"
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" || true

  echo "Deleting Argo CD root app if present..."
  kubectl delete app root-app -n "$ARGOCD_NS" --ignore-not-found=true || true

  echo "Deleting generated Argo CD applications..."
  kubectl delete applications.argoproj.io --all -n "$ARGOCD_NS" --ignore-not-found=true || true

  echo "Deleting generated ApplicationSets..."
  kubectl delete applicationsets.argoproj.io --all -n "$ARGOCD_NS" --ignore-not-found=true || true

  echo "Deleting application namespaces..."
  kubectl delete namespace reloader --ignore-not-found=true || true
  kubectl delete namespace monitoring --ignore-not-found=true || true
  kubectl delete namespace logging --ignore-not-found=true || true
  kubectl delete namespace external-secrets --ignore-not-found=true || true
  kubectl delete namespace external-dns --ignore-not-found=true || true
  kubectl delete namespace karpenter --ignore-not-found=true || true

  echo "Deleting Argo CD namespace..."
  kubectl delete namespace "$ARGOCD_NS" --ignore-not-found=true || true

  echo "Deleting cluster-scoped GitOps resources..."
  kubectl delete clustersecretstore.external-secrets.io aws-secrets-manager --ignore-not-found=true || true
  kubectl delete nodepool.karpenter.sh workload --ignore-not-found=true || true
  kubectl delete ec2nodeclass.karpenter.k8s.aws workload --ignore-not-found=true || true

  echo "Deleting Argo CD CRDs..."
  kubectl delete crd applications.argoproj.io --ignore-not-found=true || true
  kubectl delete crd applicationsets.argoproj.io --ignore-not-found=true || true
  kubectl delete crd appprojects.argoproj.io --ignore-not-found=true || true

  echo "Deleting External Secrets CRDs..."
  kubectl delete crd externalsecrets.external-secrets.io --ignore-not-found=true || true
  kubectl delete crd secretstores.external-secrets.io --ignore-not-found=true || true
  kubectl delete crd clustersecretstores.external-secrets.io --ignore-not-found=true || true
  kubectl delete crd clusterexternalsecrets.external-secrets.io --ignore-not-found=true || true

  echo "Deleting Karpenter CRDs..."
  kubectl delete crd nodepools.karpenter.sh --ignore-not-found=true || true
  kubectl delete crd nodeclaims.karpenter.sh --ignore-not-found=true || true
  kubectl delete crd ec2nodeclasses.karpenter.k8s.aws --ignore-not-found=true || true

else
  echo "Terraform outputs cluster_name/region not available. Skipping Kubernetes cleanup."
fi

echo "Running Terraform destroy..."
terraform destroy -auto-approve

echo "Cleanup completed successfully."