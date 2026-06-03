#!/usr/bin/env bash
set -uo pipefail

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
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"

# Shared helper: terminate all EC2 instances tagged by Karpenter for this cluster.
# Called both as a fallback inside cleanup_kubernetes_resources and from
# cleanup_karpenter_ec2_instances for the direct AWS-level pass.
_force_terminate_karpenter_instances() {
  local instance_ids=""

  for filter_tag in "karpenter.sh/managed-by" "karpenter.k8s.aws/cluster"; do
    local ids
    ids="$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --filters \
        "Name=tag:${filter_tag},Values=${CLUSTER_NAME}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text 2>/dev/null || true)"
    instance_ids="$(printf '%s\n%s' "$instance_ids" "$ids")"
  done

  # Also catch instances tagged with the nodepool label (belt-and-suspenders)
  local nodepool_ids
  nodepool_ids="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag-key,Values=karpenter.sh/nodepool" \
      "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || true)"
  instance_ids="$(printf '%s\n%s' "$instance_ids" "$nodepool_ids")"

  # Deduplicate and strip blanks
  local unique_ids
  unique_ids="$(echo "$instance_ids" | tr ' ' '\n' | sort -u | grep -v '^$' | xargs)"

  if [[ -z "$unique_ids" ]]; then
    echo "No Karpenter EC2 instances found to terminate."
    return 0
  fi

  echo "Terminating Karpenter EC2 instances: $unique_ids"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances \
    --region "$AWS_REGION" \
    --instance-ids $unique_ids || true

  echo "Waiting for Karpenter EC2 instances to reach terminated state..."
  for i in $(seq 1 24); do
    local remaining
    # shellcheck disable=SC2086
    remaining="$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --instance-ids $unique_ids \
      --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text 2>/dev/null | wc -w | tr -d ' ')"

    if [[ "$remaining" == "0" ]]; then
      echo "All Karpenter EC2 instances terminated."
      return 0
    fi

    echo "  $remaining instance(s) still terminating... ($i/24)"
    sleep 15
  done

  echo "WARNING: Some Karpenter EC2 instances may not have terminated. Continuing..."
}

# AWS-level Karpenter EC2 cleanup pass (runs after Kubernetes cleanup in case
# any instances escaped controller-driven termination).
cleanup_karpenter_ec2_instances() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Terraform outputs cluster_name/region not available. Skipping Karpenter EC2 cleanup."
    return 0
  fi

  echo "Running direct AWS cleanup of any remaining Karpenter EC2 instances..."
  _force_terminate_karpenter_instances
}

cleanup_leftover_vpc() {
  if [[ -z "$AWS_REGION" ]]; then
    echo "AWS_REGION not available. Skipping VPC cleanup."
    return 0
  fi

  # Resolve VPC ID: prefer Terraform output, fall back to cluster tag.
  local vpc_id="$VPC_ID"
  if [[ -z "$vpc_id" && -n "$CLUSTER_NAME" ]]; then
    vpc_id="$(aws ec2 describe-vpcs \
      --region "$AWS_REGION" \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
      --query "Vpcs[0].VpcId" \
      --output text 2>/dev/null || true)"
    [[ "$vpc_id" == "None" ]] && vpc_id=""
  fi

  if [[ -z "$vpc_id" ]]; then
    echo "VPC ID not found. Skipping VPC cleanup."
    return 0
  fi

  echo "Cleaning up leftover VPC: $vpc_id"

  # 1. Terminate every non-terminated EC2 instance still in the VPC.
  #    This is the primary reason terraform destroy fails to delete the VPC.
  echo "  Terminating remaining EC2 instances in VPC $vpc_id..."
  local instance_ids
  instance_ids="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=vpc-id,Values=${vpc_id}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || true)"

  if [[ -n "$instance_ids" ]]; then
    echo "  Terminating: $instance_ids"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids $instance_ids || true

    echo "  Waiting for instances to terminate..."
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated \
      --region "$AWS_REGION" \
      --instance-ids $instance_ids 2>/dev/null || true
  fi

  # 2. Delete NAT Gateways (must be deleted before subnets; they take time).
  echo "  Deleting NAT Gateways in VPC $vpc_id..."
  local nat_ids
  nat_ids="$(aws ec2 describe-nat-gateways \
    --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query "NatGateways[?State!='deleted'].NatGatewayId" \
    --output text 2>/dev/null || true)"

  for nat_id in $nat_ids; do
    echo "  Deleting NAT Gateway: $nat_id"
    aws ec2 delete-nat-gateway \
      --region "$AWS_REGION" \
      --nat-gateway-id "$nat_id" || true
  done

  if [[ -n "$nat_ids" ]]; then
    echo "  Waiting for NAT Gateways to delete..."
    for i in $(seq 1 20); do
      local pending
      # shellcheck disable=SC2086
      pending="$(aws ec2 describe-nat-gateways \
        --region "$AWS_REGION" \
        --nat-gateway-ids $nat_ids \
        --query "NatGateways[?State!='deleted'].NatGatewayId" \
        --output text 2>/dev/null | wc -w | tr -d ' ')"
      [[ "$pending" == "0" ]] && break
      echo "  $pending NAT Gateway(s) still deleting... ($i/20)"
      sleep 15
    done
  fi

  # 3. Detach and delete the Internet Gateway.
  echo "  Detaching Internet Gateway from VPC $vpc_id..."
  local igw_id
  igw_id="$(aws ec2 describe-internet-gateways \
    --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query "InternetGateways[0].InternetGatewayId" \
    --output text 2>/dev/null || true)"
  [[ "$igw_id" == "None" ]] && igw_id=""

  if [[ -n "$igw_id" ]]; then
    aws ec2 detach-internet-gateway \
      --region "$AWS_REGION" \
      --internet-gateway-id "$igw_id" \
      --vpc-id "$vpc_id" || true
    aws ec2 delete-internet-gateway \
      --region "$AWS_REGION" \
      --internet-gateway-id "$igw_id" || true
    echo "  Deleted Internet Gateway: $igw_id"
  fi

  # 4. Delete VPC Endpoints.
  echo "  Deleting VPC Endpoints in VPC $vpc_id..."
  local endpoint_ids
  endpoint_ids="$(aws ec2 describe-vpc-endpoints \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" \
    --output text 2>/dev/null || true)"

  if [[ -n "$endpoint_ids" ]]; then
    # shellcheck disable=SC2086
    aws ec2 delete-vpc-endpoints \
      --region "$AWS_REGION" \
      --vpc-endpoint-ids $endpoint_ids || true
    echo "  Deleted endpoints: $endpoint_ids"
  fi

  # 5. Release leftover Elastic Network Interfaces.
  echo "  Deleting leftover ENIs in VPC $vpc_id..."
  local eni_ids
  eni_ids="$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "NetworkInterfaces[].NetworkInterfaceId" \
    --output text 2>/dev/null || true)"

  for eni_id in $eni_ids; do
    local attachment_id
    attachment_id="$(aws ec2 describe-network-interfaces \
      --region "$AWS_REGION" \
      --network-interface-ids "$eni_id" \
      --query "NetworkInterfaces[0].Attachment.AttachmentId" \
      --output text 2>/dev/null || true)"
    [[ "$attachment_id" != "None" && -n "$attachment_id" ]] && \
      aws ec2 detach-network-interface \
        --region "$AWS_REGION" \
        --attachment-id "$attachment_id" \
        --force || true
    aws ec2 delete-network-interface \
      --region "$AWS_REGION" \
      --network-interface-id "$eni_id" || true
  done

  # 6. Delete all non-main route tables.
  echo "  Deleting route tables in VPC $vpc_id..."
  local rt_ids
  rt_ids="$(aws ec2 describe-route-tables \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "RouteTables[?Associations[?Main!=\`true\`] || !Associations].RouteTableId" \
    --output text 2>/dev/null || true)"

  for rt_id in $rt_ids; do
    aws ec2 delete-route-table \
      --region "$AWS_REGION" \
      --route-table-id "$rt_id" 2>/dev/null || true
  done

  # 7. Delete all subnets.
  echo "  Deleting subnets in VPC $vpc_id..."
  local subnet_ids
  subnet_ids="$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "Subnets[].SubnetId" \
    --output text 2>/dev/null || true)"

  for subnet_id in $subnet_ids; do
    aws ec2 delete-subnet \
      --region "$AWS_REGION" \
      --subnet-id "$subnet_id" || true
  done

  # 8. Delete non-default security groups.
  echo "  Deleting security groups in VPC $vpc_id..."
  local sg_ids
  sg_ids="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || true)"

  for sg_id in $sg_ids; do
    aws ec2 delete-security-group \
      --region "$AWS_REGION" \
      --group-id "$sg_id" 2>/dev/null || true
  done

  # 9. Delete the VPC itself.
  echo "  Deleting VPC: $vpc_id"
  if aws ec2 delete-vpc \
    --region "$AWS_REGION" \
    --vpc-id "$vpc_id" 2>/dev/null; then
    echo "  VPC $vpc_id deleted."
  else
    echo "  WARNING: Could not delete VPC $vpc_id. There may be remaining dependencies."
    echo "  Run: aws ec2 describe-vpc-attribute --vpc-id $vpc_id --region $AWS_REGION"
  fi
}

verify_cleanup() {
  if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
    echo "Skipping verification (cluster_name/region not available)."
    return 0
  fi

  echo ""
  echo "=== Post-destroy verification ==="
  local issues=0

  echo "Checking for remaining Karpenter EC2 instances..."
  local karpenter_instances=""
  for filter_tag in "karpenter.sh/managed-by" "karpenter.k8s.aws/cluster"; do
    local ids
    ids="$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --filters \
        "Name=tag:${filter_tag},Values=${CLUSTER_NAME}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text 2>/dev/null || true)"
    karpenter_instances="$(printf '%s %s' "$karpenter_instances" "$ids")"
  done
  karpenter_instances="$(echo "$karpenter_instances" | tr ' ' '\n' | sort -u | grep -v '^$' | xargs)"
  if [[ -n "$karpenter_instances" ]]; then
    echo "  WARNING: Karpenter EC2 instances still present: $karpenter_instances"
    issues=$((issues + 1))
  else
    echo "  OK: No Karpenter EC2 instances."
  fi

  echo "Checking for remaining ALB/NLB load balancers..."
  local lb_arns
  lb_arns="$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, '${CLUSTER_NAME}')].LoadBalancerArn" \
    --output text 2>/dev/null || true)"
  if [[ -n "$lb_arns" ]]; then
    echo "  WARNING: Load balancer(s) still present: $lb_arns"
    issues=$((issues + 1))
  else
    echo "  OK: No cluster load balancers found."
  fi

  echo "Checking for remaining EBS volumes..."
  local ebs_ids
  ebs_ids="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "Volumes[].VolumeId" \
    --output text 2>/dev/null || true)"
  if [[ -n "$ebs_ids" ]]; then
    echo "  WARNING: EBS volumes still present: $ebs_ids"
    issues=$((issues + 1))
  else
    echo "  OK: No cluster EBS volumes found."
  fi

  echo "Checking for remaining cluster security groups..."
  local sg_ids
  sg_ids="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "SecurityGroups[].GroupId" \
    --output text 2>/dev/null || true)"
  if [[ -n "$sg_ids" ]]; then
    echo "  WARNING: Security group(s) still present: $sg_ids"
    issues=$((issues + 1))
  else
    echo "  OK: No cluster security groups found."
  fi

  echo "Checking for remaining VPC..."
  local check_vpc="${VPC_ID}"
  if [[ -z "$check_vpc" && -n "$CLUSTER_NAME" ]]; then
    check_vpc="$(aws ec2 describe-vpcs \
      --region "$AWS_REGION" \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
      --query "Vpcs[0].VpcId" \
      --output text 2>/dev/null || true)"
    [[ "$check_vpc" == "None" ]] && check_vpc=""
  fi
  if [[ -n "$check_vpc" ]]; then
    echo "  WARNING: VPC $check_vpc still exists."
    issues=$((issues + 1))
  else
    echo "  OK: VPC deleted."
  fi

  echo "Checking for remaining Terraform-managed resources..."
  local tf_resources
  tf_resources="$(terraform show -json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    state = json.load(sys.stdin)
    resources = state.get('values', {}).get('root_module', {}).get('resources', [])
    print(len(resources))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"
  if [[ "$tf_resources" == "0" ]]; then
    echo "  OK: Terraform state is empty."
  elif [[ "$tf_resources" == "unknown" ]]; then
    echo "  INFO: Could not parse Terraform state. Verify manually with: terraform show"
  else
    echo "  WARNING: $tf_resources Terraform resource(s) still in state. Run 'terraform show' to review."
    issues=$((issues + 1))
  fi

  echo ""
  if [[ "$issues" -eq 0 ]]; then
    echo "Verification passed: all resources cleaned up successfully."
  else
    echo "Verification found $issues issue(s). Review the warnings above before considering cleanup complete."
  fi
}

_force_remove_namespaced_finalizers() {
  local resource_type="$1"

  kubectl get "$resource_type" --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns name; do
        [[ -z "${ns:-}" || -z "${name:-}" ]] && continue
        echo "  Removing finalizers from ${resource_type}/${name} in namespace ${ns}"
        kubectl patch "$resource_type" "$name" \
          -n "$ns" \
          --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
}

# Best-effort helper: force-delete a namespaced resource type.
_force_delete_namespaced_resources() {
  local resource_type="$1"

  kubectl get "$resource_type" --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns name; do
        [[ -z "${ns:-}" || -z "${name:-}" ]] && continue
        echo "  Force deleting ${resource_type}/${name} in namespace ${ns}"
        kubectl delete "$resource_type" "$name" \
          -n "$ns" \
          --ignore-not-found=true \
          --grace-period=0 \
          --force \
          --wait=false >/dev/null 2>&1 || true
      done
}

# Best-effort helper: remove Kubernetes finalizers from a cluster-scoped resource type.
_force_remove_cluster_finalizers() {
  local resource_type="$1"

  kubectl get "$resource_type" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r name; do
        [[ -z "${name:-}" ]] && continue
        echo "  Removing finalizers from ${resource_type}/${name}"
        kubectl patch "$resource_type" "$name" \
          --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
}

# Best-effort helper: force-delete a cluster-scoped resource type.
_force_delete_cluster_resources() {
  local resource_type="$1"

  kubectl get "$resource_type" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r name; do
        [[ -z "${name:-}" ]] && continue
        echo "  Force deleting ${resource_type}/${name}"
        kubectl delete "$resource_type" "$name" \
          --ignore-not-found=true \
          --grace-period=0 \
          --force \
          --wait=false >/dev/null 2>&1 || true
      done
}

# Best-effort helper: remove namespace finalizers.
_force_remove_namespace_finalizers() {
  kubectl get ns \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns; do
        [[ -z "${ns:-}" ]] && continue
        case "$ns" in
          kube-system|kube-public|kube-node-lease|default)
            continue
            ;;
        esac

        echo "  Removing finalizers from namespace/${ns}"
        kubectl patch namespace "$ns" \
          --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
}

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

  echo "NUKE MODE: stopping GitOps/controllers..."

  kubectl scale statefulset argocd-application-controller \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  kubectl scale deployment argocd-applicationset-controller \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  kubectl scale deployment argocd-repo-server \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  kubectl scale deployment argocd-server \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  kubectl scale deployment argocd-dex-server \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  kubectl scale deployment argocd-redis \
    -n "$ARGOCD_NS" \
    --replicas=0 >/dev/null 2>&1 || true

  echo "Deleting Argo CD controller workloads and pods..."
  kubectl delete statefulset argocd-application-controller \
    -n "$ARGOCD_NS" \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  kubectl delete deployment \
    -n "$ARGOCD_NS" \
    -l app.kubernetes.io/part-of=argocd \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  kubectl delete pod \
    -n "$ARGOCD_NS" \
    -l app.kubernetes.io/part-of=argocd \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  # Also stop common reconcilers that may keep cloud resources alive or recreate resources.
  echo "Stopping common platform controllers..."
  kubectl delete deployment \
    -n kube-system \
    aws-load-balancer-controller \
    external-dns \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  kubectl delete deployment \
    -n karpenter \
    karpenter \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  kubectl delete deployment \
    -n external-secrets \
    external-secrets \
    external-secrets-cert-controller \
    external-secrets-webhook \
    --ignore-not-found=true \
    --grace-period=0 \
    --force \
    --wait=false >/dev/null 2>&1 || true

  echo "Removing finalizers from Argo CD custom resources..."
  _force_remove_namespaced_finalizers applications.argoproj.io
  _force_remove_namespaced_finalizers applicationsets.argoproj.io
  _force_remove_namespaced_finalizers appprojects.argoproj.io

  echo "Force deleting Argo CD custom resources..."
  _force_delete_namespaced_resources applicationsets.argoproj.io
  _force_delete_namespaced_resources applications.argoproj.io
  _force_delete_namespaced_resources appprojects.argoproj.io

  echo "Force deleting ALL Kubernetes Ingresses..."
  _force_remove_namespaced_finalizers ingress
  _force_delete_namespaced_resources ingress

  echo "Force deleting ALL Kubernetes LoadBalancer Services..."
  kubectl get service --all-namespaces \
    --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns name; do
        [[ -z "${ns:-}" || -z "${name:-}" ]] && continue
        echo "  Force deleting service/${name} in namespace ${ns}"
        kubectl patch service "$name" \
          -n "$ns" \
          --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        kubectl delete service "$name" \
          -n "$ns" \
          --ignore-not-found=true \
          --grace-period=0 \
          --force \
          --wait=false >/dev/null 2>&1 || true
      done

  echo "Verifying Ingress and LoadBalancer Service removal..."
  for i in $(seq 1 8); do
    local lb_service_count
    local ingress_count

    lb_service_count="$(kubectl get service --all-namespaces \
      --field-selector spec.type=LoadBalancer \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    ingress_count="$(kubectl get ingress --all-namespaces \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$lb_service_count" == "0" && "$ingress_count" == "0" ]]; then
      echo "Kubernetes Ingresses and LoadBalancer Services removed from API."
      break
    fi

    echo "  Still present - LoadBalancer Services: $lb_service_count, Ingresses: $ingress_count ($i/8)"
    _force_remove_namespaced_finalizers ingress
    _force_delete_namespaced_resources ingress
    sleep 5
  done

  echo "Force deleting Karpenter resources..."
  _force_remove_cluster_finalizers nodepool.karpenter.sh
  _force_remove_cluster_finalizers nodeclaim.karpenter.sh
  _force_remove_cluster_finalizers ec2nodeclass.karpenter.k8s.aws
  _force_delete_cluster_resources nodeclaim.karpenter.sh
  _force_delete_cluster_resources nodepool.karpenter.sh
  _force_delete_cluster_resources ec2nodeclass.karpenter.k8s.aws

  echo "Force terminating Karpenter EC2 instances at AWS level..."
  _force_terminate_karpenter_instances

  echo "Force deleting PersistentVolumeClaims and PersistentVolumes..."
  _force_remove_namespaced_finalizers pvc
  _force_delete_namespaced_resources pvc
  _force_remove_cluster_finalizers pv
  _force_delete_cluster_resources pv

  echo "Force deleting platform namespaces..."
  kubectl get ns \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns; do
        [[ -z "${ns:-}" ]] && continue
        case "$ns" in
          kube-system|kube-public|kube-node-lease|default)
            continue
            ;;
        esac

        echo "  Force deleting namespace/${ns}"
        kubectl patch namespace "$ns" \
          --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        kubectl delete namespace "$ns" \
          --ignore-not-found=true \
          --grace-period=0 \
          --force \
          --wait=false >/dev/null 2>&1 || true
      done

  echo "Removing namespace finalizers again..."
  _force_remove_namespace_finalizers

  echo "Force deleting known CRDs..."
  kubectl delete crd applications.argoproj.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd applicationsets.argoproj.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd appprojects.argoproj.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true

  kubectl delete crd externalsecrets.external-secrets.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd secretstores.external-secrets.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd clustersecretstores.external-secrets.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd clusterexternalsecrets.external-secrets.io --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true

  kubectl delete crd nodepools.karpenter.sh --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd nodeclaims.karpenter.sh --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  kubectl delete crd ec2nodeclasses.karpenter.k8s.aws --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true

  kubectl get crd -o name 2>/dev/null \
    | grep -E '\.(kyverno\.io|wgpolicyk8s\.io)$' \
    | xargs -r kubectl delete --ignore-not-found=true --grace-period=0 --force --wait=false >/dev/null 2>&1 || true

  echo "Kubernetes nuke pass completed. AWS cleanup will remove leftover ALBs/NLBs/SGs/EBS/S3."
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
cleanup_karpenter_ec2_instances

cleanup_s3_buckets

terraform destroy -auto-approve -input=false

cleanup_leftover_aws_load_balancers
cleanup_leftover_aws_security_groups
cleanup_ebs_volumes_and_snapshots
cleanup_leftover_vpc

verify_cleanup

echo "Cleanup completed."