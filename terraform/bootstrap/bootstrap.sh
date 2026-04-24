#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

ARGOCD_NS="argocd"
ARGOCD_INSTALL="${ROOT_DIR}/bootstrap/argocd-install.yaml"
ROOT_APP="${ROOT_DIR}/gitops/bootstrap/root-app.yaml"

echo "Running Terraform..."
cd "$TF_DIR"
terraform init
terraform apply -auto-approve

CLUSTER_NAME="$(terraform output -raw cluster_name)"
AWS_REGION="$(terraform output -raw region)"
AWS_ACCOUNT_ID="$(terraform output -raw account_id)"

echo "Updating kubeconfig..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

echo "Waiting for EKS API..."
CLUSTER_ENDPOINT="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.endpoint" \
  --output text)"

HOSTNAME="$(echo "$CLUSTER_ENDPOINT" | sed 's|https://||' | sed 's|/||g')"

echo "Waiting for EKS API DNS resolution..."
echo "Cluster endpoint: $CLUSTER_ENDPOINT"
echo "API hostname: $HOSTNAME"

for i in $(seq 1 40); do
  echo "Attempt $i/40: checking DNS for $HOSTNAME..."

  if nslookup "$HOSTNAME" >/dev/null 2>&1; then
    echo "DNS resolved successfully on attempt $i."
    echo "Sleeping 30s for EKS API propagation to stabilise..."
    sleep 30
    echo "EKS API DNS check completed."
    break
  fi

  echo "DNS not resolved yet. Retrying in 15s..."
  sleep 15

  if [[ "$i" == "40" ]]; then
    echo "ERROR: EKS API server DNS did not resolve within 10 minutes."
    echo "Hostname: $HOSTNAME"
    exit 1
  fi
done

echo "Creating Argo CD namespace..."
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Argo CD..."
kubectl apply -n "$ARGOCD_NS" -f "$ARGOCD_INSTALL"

echo "Waiting for Argo CD..."
kubectl rollout status deploy/argocd-server -n "$ARGOCD_NS" --timeout=10m
kubectl rollout status deploy/argocd-repo-server -n "$ARGOCD_NS" --timeout=10m
kubectl rollout status sts/argocd-application-controller -n "$ARGOCD_NS" --timeout=10m

echo "Creating Argo CD cluster secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_NAME}-${AWS_REGION}
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: dev
    region: ${AWS_REGION}
    cloud: aws
  annotations:
    aws-account-id: "${AWS_ACCOUNT_ID}"
type: Opaque
stringData:
  name: in-cluster-local
  server: https://kubernetes.default.svc
  config: |
    {
      "tlsClientConfig": {
        "insecure": false
      }
    }
EOF

echo "Applying root app..."
kubectl apply -f "$ROOT_APP"

echo "Bootstrap completed successfully."