#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TF_DIR="${ROOT_DIR}/terraform"
PROJECTS_DIR="${ROOT_DIR}/gitops/argocd/projects"

ARGOCD_NS="argocd"

echo "Running upgrade..."

REQUIRED_COMMANDS=(
  terraform
  aws
  kubectl
  openssl
  git
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

# htpasswd is required for bcrypt hashing.
if ! command -v htpasswd >/dev/null 2>&1; then
  if [[ -x "/opt/homebrew/opt/httpd/bin/htpasswd" ]]; then
    export PATH="/opt/homebrew/opt/httpd/bin:$PATH"
  elif [[ -x "/usr/local/opt/httpd/bin/htpasswd" ]]; then
    export PATH="/usr/local/opt/httpd/bin:$PATH"
  else
    echo "ERROR: htpasswd is required for bcrypt hashing."
    echo "Install on macOS using: brew install httpd"
    echo "Then add to PATH if needed:"
    echo "  export PATH=\"/opt/homebrew/opt/httpd/bin:\$PATH\""
    exit 1
  fi
fi

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: Terraform directory not found: $TF_DIR"
  exit 1
fi

validate_bcrypt_hash() {
  local hash="$1"

  if [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    return 0
  fi

  return 1
}

echo "Preparing secrets..."

if [[ -z "${TF_VAR_alertmanager_slack_webhook_url:-}" ]]; then
  echo "ERROR: TF_VAR_alertmanager_slack_webhook_url is required."
  exit 1
fi

if [[ -n "${TF_VAR_argocd_admin_password_hash:-}" ]]; then
  echo "Using provided TF_VAR_argocd_admin_password_hash."

  if ! validate_bcrypt_hash "$TF_VAR_argocd_admin_password_hash"; then
    echo "ERROR: TF_VAR_argocd_admin_password_hash is not a valid bcrypt hash."
    exit 1
  fi
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
fi

if [[ -n "${TF_VAR_grafana_admin_password:-}" ]]; then
  echo "Using provided TF_VAR_grafana_admin_password."
else
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

  if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    echo "Generated Grafana admin password."
  else
    echo "Using provided GRAFANA_ADMIN_PASSWORD."
  fi

  export TF_VAR_grafana_admin_password="$GRAFANA_ADMIN_PASSWORD"
fi


echo "Running Terraform..."
cd "$TF_DIR"

terraform init -input=false
terraform validate
terraform apply -auto-approve -input=false

echo "Reading Terraform outputs..."

CLUSTER_NAME="$(terraform output -raw cluster_name)"
AWS_REGION="$(terraform output -raw region)"
AWS_ACCOUNT_ID="$(terraform output -raw account_id)"
VPC_ID="$(terraform output -raw vpc_id)"
DOMAIN_NAME="$(terraform output -raw domain_name)"
KARPENTER_INSTANCE_PROFILE_NAME="$(terraform output -raw karpenter_instance_profile_name 2>/dev/null || true)"
THANOS_BUCKET_NAME="$(terraform output -raw thanos_bucket_name 2>/dev/null || true)"
LOKI_BUCKET_NAME="$(terraform output -raw loki_bucket_name 2>/dev/null || true)"
VELERO_BUCKET_NAME="$(terraform output -raw velero_bucket_name 2>/dev/null || true)"
# tempo_bucket_name was missing here while gitops/tracing/tempo/tempo.yaml reads
# the annotation with missingkey=error. Because this script re-applies the whole
# cluster Secret, omitting an output silently strips its annotation and the
# ApplicationSet then fails to generate. Every annotation the manifests consume
# has to be read here.
TEMPO_BUCKET_NAME="$(terraform output -raw tempo_bucket_name 2>/dev/null || true)"
MLOPS_PIPELINE_ROLE_ARN="$(terraform output -raw mlops_pipeline_role_arn 2>/dev/null || true)"
MLOPS_SERVING_ROLE_ARN="$(terraform output -raw mlops_serving_role_arn 2>/dev/null || true)"
ARC_RUNNER_ROLE_ARN="$(terraform output -raw arc_runner_role_arn 2>/dev/null || true)"
GITHUB_CONFIG_URL="$(terraform output -raw github_config_url 2>/dev/null || true)"

# Gates the platform runner scale set - see the same block in bootstrap.sh.
if [[ -n "$GITHUB_CONFIG_URL" ]]; then
  GITHUB_RUNNERS_LABEL="enabled"
else
  GITHUB_RUNNERS_LABEL="disabled"
fi

echo "Updating kubeconfig..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

echo "Refreshing ArgoCD cluster secret..."

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
    github-runners: "${GITHUB_RUNNERS_LABEL}"
  annotations:
    aws-account-id: "${AWS_ACCOUNT_ID}"
    cluster-name: "${CLUSTER_NAME}"
    vpc-id: "${VPC_ID}"
    domain-name: "${DOMAIN_NAME}"
    karpenter-instance-profile-name: "${KARPENTER_INSTANCE_PROFILE_NAME}"
    thanos-bucket-name: "${THANOS_BUCKET_NAME}"
    loki-bucket-name: "${LOKI_BUCKET_NAME}"
    velero-bucket-name: "${VELERO_BUCKET_NAME}"
    tempo-bucket-name: "${TEMPO_BUCKET_NAME}"
    mlops-pipeline-role-arn: "${MLOPS_PIPELINE_ROLE_ARN}"
    mlops-serving-role-arn: "${MLOPS_SERVING_ROLE_ARN}"
    arc-runner-role-arn: "${ARC_RUNNER_ROLE_ARN}"
    github-config-url: "${GITHUB_CONFIG_URL}"
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

REFRESH_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "Refreshing ExternalSecrets..."

# Annotate every ExternalSecret in the cluster rather than an explicit list.
# Reloader rolls any Deployment whose referenced Secret changes, so a secret
# that is not refreshed here silently keeps serving the old value until External
# Secrets' own refreshInterval (1h) comes round. An explicit list goes stale
# every time a component adds a secret - arc-github-app in arc-runners was
# missed exactly that way.
kubectl annotate externalsecret --all --all-namespaces \
  force-sync="${REFRESH_TS}" \
  --overwrite || true


echo "Applying ArgoCD projects..."
kubectl apply -f "$PROJECTS_DIR/"

echo
echo "Upgrade completed successfully."