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

  echo "Checking Kubernetes API server connectivity..."
  if ! kubectl cluster-info --request-timeout=15s >/dev/null 2>&1; then
    echo "WARNING: Kubernetes API server unreachable (cluster may already be deleted). Skipping Kubernetes resource cleanup."
    return 0
  fi

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

  echo "Deleting Kyverno CRDs..."
  kubectl get crd -o name 2>/dev/null \
    | grep -E '\.(kyverno\.io|wgpolicyk8s\.io)$' \
    | xargs -r kubectl delete --ignore-not-found=true --wait=false || true
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

cleanup_leftover_aws_security_groups() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Terraform outputs cluster_name/region not available. Skipping Security Group cleanup."
    return 0
  fi

  echo "Deleting leftover Security Groups created by the ingress controller for cluster: $CLUSTER_NAME..."

  # AWS Load Balancer Controller tags SGs it creates with elbv2.k8s.aws/cluster or ingress.k8s.aws/cluster
  for TAG_KEY in "elbv2.k8s.aws/cluster" "ingress.k8s.aws/cluster"; do
    SG_IDS="$(aws ec2 describe-security-groups \
      --region "$AWS_REGION" \
      --filters "Name=tag:${TAG_KEY},Values=${CLUSTER_NAME}" \
      --query "SecurityGroups[].GroupId" \
      --output text 2>/dev/null || true)"

    for sg_id in $SG_IDS; do
      echo "Deleting ingress-controller Security Group: $sg_id (tag: ${TAG_KEY})"
      # Revoke all ingress/egress rules first to break cross-SG dependencies
      aws ec2 revoke-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --ip-permissions \
          "$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --group-ids "$sg_id" \
            --query "SecurityGroups[0].IpPermissions" \
            --output json 2>/dev/null)" 2>/dev/null || true
      aws ec2 revoke-security-group-egress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --ip-permissions \
          "$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --group-ids "$sg_id" \
            --query "SecurityGroups[0].IpPermissionsEgress" \
            --output json 2>/dev/null)" 2>/dev/null || true
      aws ec2 delete-security-group \
        --region "$AWS_REGION" \
        --group-id "$sg_id" || true
    done
  done

  # Also catch any SGs owned by the cluster that look like LBC-managed ones
  # (named k8s-* which is the LBC naming convention)
  SG_IDS_OWNED="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      "Name=group-name,Values=k8s-*" \
    --query "SecurityGroups[].GroupId" \
    --output text 2>/dev/null || true)"

  for sg_id in $SG_IDS_OWNED; do
    echo "Deleting cluster-owned LBC Security Group: $sg_id"
    aws ec2 revoke-security-group-ingress \
      --region "$AWS_REGION" \
      --group-id "$sg_id" \
      --ip-permissions \
        "$(aws ec2 describe-security-groups \
          --region "$AWS_REGION" \
          --group-ids "$sg_id" \
          --query "SecurityGroups[0].IpPermissions" \
          --output json 2>/dev/null)" 2>/dev/null || true
    aws ec2 revoke-security-group-egress \
      --region "$AWS_REGION" \
      --group-id "$sg_id" \
      --ip-permissions \
        "$(aws ec2 describe-security-groups \
          --region "$AWS_REGION" \
          --group-ids "$sg_id" \
          --query "SecurityGroups[0].IpPermissionsEgress" \
          --output json 2>/dev/null)" 2>/dev/null || true
    aws ec2 delete-security-group \
      --region "$AWS_REGION" \
      --group-id "$sg_id" || true
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

cleanup_s3_buckets() {
  if [[ -z "$AWS_REGION" ]]; then
    echo "AWS_REGION not available. Skipping S3 bucket cleanup."
    return 0
  fi

  echo "Finding S3 buckets tagged for cluster cleanup..."

  ALL_BUCKETS="$(aws s3api list-buckets \
    --query "Buckets[].Name" \
    --output text 2>/dev/null || true)"

  for bucket in $ALL_BUCKETS; do
    BUCKET_REGION="$(aws s3api get-bucket-location \
      --bucket "$bucket" \
      --query "LocationConstraint" \
      --output text 2>/dev/null || true)"

    # Normalize us-east-1 which returns "None"
    [[ "$BUCKET_REGION" == "None" ]] && BUCKET_REGION="us-east-1"

    [[ "$BUCKET_REGION" != "$AWS_REGION" ]] && continue

    TAGS="$(aws s3api get-bucket-tagging \
      --bucket "$bucket" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null || true)"

    CLUSTER_TAG="$(echo "$TAGS" \
      | python3 -c "
import sys, json
tags = json.load(sys.stdin).get('TagSet', [])
print(next((t['Value'] for t in tags if t['Key'] in ('kubernetes.io/cluster/${CLUSTER_NAME}', 'velero-cluster', 'Cluster')), ''))
" 2>/dev/null || true)"

    VELERO_TAG="$(echo "$TAGS" \
      | python3 -c "
import sys, json
tags = json.load(sys.stdin).get('TagSet', [])
print(next((t['Value'] for t in tags if 'velero' in t['Key'].lower()), ''))
" 2>/dev/null || true)"

    NAME_MATCH=false
    [[ -n "$CLUSTER_NAME" && "$bucket" == *"$CLUSTER_NAME"* ]] && NAME_MATCH=true
    [[ "$bucket" == *"velero"* && -n "$CLUSTER_NAME" ]] && NAME_MATCH=true

    if [[ -n "$CLUSTER_TAG" || -n "$VELERO_TAG" || "$NAME_MATCH" == "true" ]]; then
      echo "Emptying versioned S3 bucket: $bucket"

      # Delete all object versions in batches
      while true; do
        VERSIONS="$(aws s3api list-object-versions \
          --bucket "$bucket" \
          --region "$AWS_REGION" \
          --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
          --max-items 1000 \
          --output json 2>/dev/null || true)"

        OBJECT_COUNT="$(echo "$VERSIONS" \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))" 2>/dev/null || echo 0)"

        [[ "$OBJECT_COUNT" == "0" ]] && break

        echo "  Deleting $OBJECT_COUNT versions..."
        echo "$VERSIONS" | aws s3api delete-objects \
          --bucket "$bucket" \
          --region "$AWS_REGION" \
          --delete file:///dev/stdin \
          --output text >/dev/null || true
      done

      # Delete all delete markers in batches
      while true; do
        MARKERS="$(aws s3api list-object-versions \
          --bucket "$bucket" \
          --region "$AWS_REGION" \
          --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
          --max-items 1000 \
          --output json 2>/dev/null || true)"

        MARKER_COUNT="$(echo "$MARKERS" \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))" 2>/dev/null || echo 0)"

        [[ "$MARKER_COUNT" == "0" ]] && break

        echo "  Deleting $MARKER_COUNT delete markers..."
        echo "$MARKERS" | aws s3api delete-objects \
          --bucket "$bucket" \
          --region "$AWS_REGION" \
          --delete file:///dev/stdin \
          --output text >/dev/null || true
      done

      echo "  Bucket $bucket is now empty."
    fi
  done
}

cleanup_kubernetes_resources
cleanup_leftover_aws_load_balancers
cleanup_leftover_aws_security_groups
cleanup_ebs_volumes_and_snapshots
cleanup_s3_buckets

echo "Running Terraform destroy..."

terraform destroy \
  -auto-approve \
  -input=false

echo "Cleanup completed successfully."