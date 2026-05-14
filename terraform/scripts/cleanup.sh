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
  seq
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

cleanup_kubernetes_resources() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Terraform outputs cluster_name/region not available. Skipping Kubernetes cleanup."
    return 0
  fi

  echo "Updating kubeconfig for cluster: $CLUSTER_NAME"
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" || true

  echo "Deleting Argo CD root app if present..."
  kubectl delete app root-app \
    -n "$ARGOCD_NS" \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting generated Argo CD Applications..."
  kubectl delete applications.argoproj.io \
    --all \
    -n "$ARGOCD_NS" \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting generated ApplicationSets..."
  kubectl delete applicationsets.argoproj.io \
    --all \
    -n "$ARGOCD_NS" \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting Kubernetes Ingresses before namespaces..."
  kubectl delete ingress \
    --all \
    --all-namespaces \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting Kubernetes LoadBalancer Services before namespaces..."
  kubectl delete service \
    --all \
    --all-namespaces \
    --field-selector spec.type=LoadBalancer \
    --ignore-not-found=true \
    --wait=false || true

  echo "Waiting for Kubernetes LoadBalancer Services and Ingresses to disappear..."
  for i in $(seq 1 20); do
    LB_SERVICE_COUNT="$(kubectl get service --all-namespaces \
      --field-selector spec.type=LoadBalancer \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    INGRESS_COUNT="$(kubectl get ingress --all-namespaces \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$LB_SERVICE_COUNT" == "0" && "$INGRESS_COUNT" == "0" ]]; then
      echo "Kubernetes LoadBalancer Services and Ingresses deleted."
      break
    fi

    echo "LoadBalancer Services: $LB_SERVICE_COUNT, Ingresses: $INGRESS_COUNT. Waiting..."
    sleep 15
  done

  echo "Deleting Karpenter NodePools while controller is still running..."
  kubectl delete nodepool.karpenter.sh \
    --all \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting Karpenter NodeClaims while controller is still running..."
  kubectl delete nodeclaim.karpenter.sh \
    --all \
    --ignore-not-found=true \
    --wait=false || true

  echo "Waiting for Karpenter-managed nodes to terminate..."
  for i in $(seq 1 24); do
    KARPENTER_NODE_COUNT="$(kubectl get nodes -l karpenter.sh/nodepool \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$KARPENTER_NODE_COUNT" == "0" ]]; then
      echo "Karpenter-managed nodes terminated."
      break
    fi

    echo "Karpenter-managed nodes still present: $KARPENTER_NODE_COUNT. Waiting..."
    sleep 15
  done

  echo "Current Karpenter-managed nodes, if any:"
  kubectl get nodes -l karpenter.sh/nodepool || true

  echo "Deleting cluster-scoped GitOps resources..."
  kubectl delete clustersecretstore.external-secrets.io aws-secrets-manager \
    --ignore-not-found=true \
    --wait=false || true

  kubectl delete ec2nodeclass.karpenter.k8s.aws \
    --all \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting PersistentVolumes (Retain policy prevents automatic deletion)..."
  kubectl delete pv \
    --all \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting platform-managed namespaces..."
  kubectl delete namespace \
    -l app.kubernetes.io/part-of=eks-gitops-platform \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting Argo CD namespace..."
  kubectl delete namespace "$ARGOCD_NS" \
    --ignore-not-found=true \
    --wait=false || true

  echo "Deleting Argo CD CRDs..."
  kubectl delete crd applications.argoproj.io --ignore-not-found=true --wait=false || true
  kubectl delete crd applicationsets.argoproj.io --ignore-not-found=true --wait=false || true
  kubectl delete crd appprojects.argoproj.io --ignore-not-found=true --wait=false || true

  echo "Deleting External Secrets CRDs..."
  kubectl delete crd externalsecrets.external-secrets.io --ignore-not-found=true --wait=false || true
  kubectl delete crd secretstores.external-secrets.io --ignore-not-found=true --wait=false || true
  kubectl delete crd clustersecretstores.external-secrets.io --ignore-not-found=true --wait=false || true
  kubectl delete crd clusterexternalsecrets.external-secrets.io --ignore-not-found=true --wait=false || true

  echo "Deleting Karpenter CRDs..."
  kubectl delete crd nodepools.karpenter.sh --ignore-not-found=true --wait=false || true
  kubectl delete crd nodeclaims.karpenter.sh --ignore-not-found=true --wait=false || true
  kubectl delete crd ec2nodeclasses.karpenter.k8s.aws --ignore-not-found=true --wait=false || true
}

cleanup_leftover_aws_load_balancers() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Terraform outputs cluster_name/region not available. Skipping AWS Load Balancer cleanup."
    return 0
  fi

  echo "Deleting leftover AWS ALB/NLB resources tagged for cluster..."

  LB_ARNS="$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[].LoadBalancerArn" \
    --output text 2>/dev/null || true)"

  for lb_arn in $LB_ARNS; do
    TAG_VALUE_K8S="$(aws elbv2 describe-tags \
      --region "$AWS_REGION" \
      --resource-arns "$lb_arn" \
      --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
      --output text 2>/dev/null || true)"

    TAG_VALUE_CLUSTER="$(aws elbv2 describe-tags \
      --region "$AWS_REGION" \
      --resource-arns "$lb_arn" \
      --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'].Value | [0]" \
      --output text 2>/dev/null || true)"

    if [[ "$TAG_VALUE_K8S" == "$CLUSTER_NAME" || "$TAG_VALUE_CLUSTER" == "owned" || "$TAG_VALUE_CLUSTER" == "shared" ]]; then
      echo "Deleting leftover ALB/NLB: $lb_arn"

      aws elbv2 delete-load-balancer \
        --region "$AWS_REGION" \
        --load-balancer-arn "$lb_arn" || true
    fi
  done

  echo "Deleting leftover Classic ELBs tagged for cluster..."

  ELB_NAMES="$(aws elb describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[].LoadBalancerName" \
    --output text 2>/dev/null || true)"

  for elb_name in $ELB_NAMES; do
    TAG_VALUE_CLUSTER="$(aws elb describe-tags \
      --region "$AWS_REGION" \
      --load-balancer-names "$elb_name" \
      --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'].Value | [0]" \
      --output text 2>/dev/null || true)"

    if [[ "$TAG_VALUE_CLUSTER" == "owned" || "$TAG_VALUE_CLUSTER" == "shared" ]]; then
      echo "Deleting leftover Classic ELB: $elb_name"

      aws elb delete-load-balancer \
        --region "$AWS_REGION" \
        --load-balancer-name "$elb_name" || true
    fi
  done
}

cleanup_ebs_volumes_and_snapshots() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Terraform outputs cluster_name/region not available. Skipping EBS cleanup."
    return 0
  fi

  echo "Deleting EBS volumes tagged for cluster: $CLUSTER_NAME..."

  VOLUME_IDS="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "Volumes[].VolumeId" \
    --output text 2>/dev/null || true)"

  for volume_id in $VOLUME_IDS; do
    echo "Deleting EBS volume: $volume_id"
    aws ec2 delete-volume \
      --region "$AWS_REGION" \
      --volume-id "$volume_id" || true
  done

  echo "Deleting Velero EBS snapshots for cluster: $CLUSTER_NAME..."

  SNAPSHOT_IDS="$(aws ec2 describe-snapshots \
    --region "$AWS_REGION" \
    --owner-ids self \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "Snapshots[].SnapshotId" \
    --output text 2>/dev/null || true)"

  for snapshot_id in $SNAPSHOT_IDS; do
    echo "Deleting EBS snapshot: $snapshot_id"
    aws ec2 delete-snapshot \
      --region "$AWS_REGION" \
      --snapshot-id "$snapshot_id" || true
  done

  echo "Deleting any remaining Velero snapshots (velero.io/backup tag)..."

  VELERO_SNAPSHOT_IDS="$(aws ec2 describe-snapshots \
    --region "$AWS_REGION" \
    --owner-ids self \
    --filters "Name=tag-key,Values=velero.io/backup" \
    --query "Snapshots[].SnapshotId" \
    --output text 2>/dev/null || true)"

  for snapshot_id in $VELERO_SNAPSHOT_IDS; do
    echo "Deleting Velero snapshot: $snapshot_id"
    aws ec2 delete-snapshot \
      --region "$AWS_REGION" \
      --snapshot-id "$snapshot_id" || true
  done
}

cleanup_kubernetes_resources
cleanup_leftover_aws_load_balancers
cleanup_ebs_volumes_and_snapshots

echo "Running Terraform destroy..."

terraform destroy \
  -auto-approve \
  -input=false

echo "Cleanup completed successfully."