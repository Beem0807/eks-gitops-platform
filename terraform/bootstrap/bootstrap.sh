#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TF_DIR="${ROOT_DIR}/terraform"

ARGOCD_NS="argocd"
ROOT_APP="${ROOT_DIR}/gitops/bootstrap/root-app.yaml"

ARGOCD_HELM_RELEASE="argocd"
ARGOCD_HELM_REPO_NAME="argo"
ARGOCD_HELM_REPO_URL="https://argoproj.github.io/argo-helm"
ARGOCD_HELM_CHART="argo/argo-cd"
ARGOCD_HELM_VERSION="9.4.17"

echo "Running preflight checks..."

REQUIRED_COMMANDS=(
  terraform
  aws
  kubectl
  openssl
  nslookup
  helm
  sed
  seq
  git
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

# htpasswd is required only when Argo CD password hash is not already provided.
if [[ -z "${TF_VAR_argocd_admin_password_hash:-}" ]]; then
  if ! command -v htpasswd >/dev/null 2>&1; then
    if [[ -x "/opt/homebrew/opt/httpd/bin/htpasswd" ]]; then
      export PATH="/opt/homebrew/opt/httpd/bin:$PATH"
    elif [[ -x "/usr/local/opt/httpd/bin/htpasswd" ]]; then
      export PATH="/usr/local/opt/httpd/bin:$PATH"
    else
      echo "ERROR: htpasswd is required for Argo CD bcrypt hashing."
      echo "Install on macOS using: brew install httpd"
      echo "Then add to PATH if needed:"
      echo "  export PATH=\"/opt/homebrew/opt/httpd/bin:\$PATH\""
      exit 1
    fi
  fi
fi

if [[ ! -f "$ROOT_APP" ]]; then
  echo "ERROR: Missing root app manifest: $ROOT_APP"
  exit 1
fi

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: Terraform directory not found: $TF_DIR"
  exit 1
fi

if [[ -z "${TF_VAR_alertmanager_slack_webhook_url:-}" ]]; then
  echo "ERROR: TF_VAR_alertmanager_slack_webhook_url is required."
  exit 1
fi

echo "Preflight checks passed."

validate_bcrypt_hash() {
  local hash="$1"

  # Accept bcrypt prefixes: $2a$, $2b$, $2y$
  if [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    return 0
  fi

  return 1
}

ARGOCD_ADMIN_PASSWORD_PRINTABLE=""

if [[ -n "${TF_VAR_argocd_admin_password_hash:-}" ]]; then
  echo "Using provided TF_VAR_argocd_admin_password_hash."

  if ! validate_bcrypt_hash "$TF_VAR_argocd_admin_password_hash"; then
    echo "ERROR: TF_VAR_argocd_admin_password_hash is not a valid bcrypt hash."
    echo "Expected format like: \$2a\$10\$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    exit 1
  fi

  ARGOCD_ADMIN_PASSWORD_PRINTABLE="<not available because hash was provided directly>"

else
  ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-}"

  if [[ -z "$ARGOCD_ADMIN_PASSWORD" ]]; then
    ARGOCD_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    echo "Generated Argo CD admin password."
  else
    echo "Using provided ARGOCD_ADMIN_PASSWORD."
  fi

  ARGOCD_ADMIN_PASSWORD_HASH="$(htpasswd -bnBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n')"

  if ! validate_bcrypt_hash "$ARGOCD_ADMIN_PASSWORD_HASH"; then
    echo "ERROR: Generated Argo CD bcrypt hash is invalid."
    exit 1
  fi

  export TF_VAR_argocd_admin_password_hash="$ARGOCD_ADMIN_PASSWORD_HASH"
  export TF_VAR_argocd_admin_password_plaintext="$ARGOCD_ADMIN_PASSWORD"

  ARGOCD_ADMIN_PASSWORD_PRINTABLE="$ARGOCD_ADMIN_PASSWORD"
fi

if [[ -n "${TF_VAR_grafana_admin_password:-}" ]]; then
  echo "Using provided TF_VAR_grafana_admin_password."
  GRAFANA_ADMIN_PASSWORD_PRINTABLE="$TF_VAR_grafana_admin_password"

else
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

  if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    echo "Generated Grafana admin password."
  else
    echo "Using provided GRAFANA_ADMIN_PASSWORD."
  fi

  export TF_VAR_grafana_admin_password="$GRAFANA_ADMIN_PASSWORD"
  GRAFANA_ADMIN_PASSWORD_PRINTABLE="$GRAFANA_ADMIN_PASSWORD"
fi

echo "Running Terraform..."
cd "$TF_DIR"
terraform init
terraform apply -auto-approve

CLUSTER_NAME="$(terraform output -raw cluster_name)"
AWS_REGION="$(terraform output -raw region)"
AWS_ACCOUNT_ID="$(terraform output -raw account_id)"
VPC_ID="$(terraform output -raw vpc_id)"
DOMAIN_NAME="$(terraform output -raw domain_name)"

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

echo "Installing Argo CD using Helm..."
helm repo add "$ARGOCD_HELM_REPO_NAME" "$ARGOCD_HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo update "$ARGOCD_HELM_REPO_NAME"

helm upgrade --install "$ARGOCD_HELM_RELEASE" "$ARGOCD_HELM_CHART" \
  --version "$ARGOCD_HELM_VERSION" \
  --namespace "$ARGOCD_NS" \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP \
  --set global.nodeSelector.app=core \
  --set global.tolerations[0].key=app \
  --set global.tolerations[0].operator=Equal \
  --set global.tolerations[0].value=core \
  --set global.tolerations[0].effect=NoSchedule \
  --wait \
  --timeout 10m

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
    cluster-name: "${CLUSTER_NAME}"
    vpc-id: "${VPC_ID}"
    domain-name: "${DOMAIN_NAME}"
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