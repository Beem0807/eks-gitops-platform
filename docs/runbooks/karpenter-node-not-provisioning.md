# Karpenter Node Not Provisioning

## Symptoms

- Pods stuck in `Pending` state for > 2 minutes
- `kubectl describe pod <name>` shows `FailedScheduling: 0/N nodes are available`
- `kubectl logs -n karpenter` shows no provisioning events or shows repeated errors
- HPA scaled up replicas but cluster capacity did not grow
- Karpenter `NodeClaim` objects exist but no EC2 instance launched

## Impact

- **High**: New pods cannot start; service is under-provisioned during traffic spike or deployment rollout
- Deployments are blocked; rollbacks may also be blocked if replacement pods can't schedule

## Quick Checks

```bash
# Pods stuck in Pending
kubectl get pods -A --field-selector=status.phase=Pending

# Why is the pod unschedulable?
kubectl describe pod <pod-name> -n <namespace> | grep -A 20 "Events:"

# Karpenter controller logs (most useful source)
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=200

# NodeClaims - are any being created?
kubectl get nodeclaims -A
kubectl describe nodeclaim <name>

# NodePool workload - check limits and current usage
kubectl get nodepool workload -o wide
kubectl describe nodepool workload

# EC2 instance activity
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=workload" \
            "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType}' \
  --region ap-south-1

# Pod Identity - confirm the association exists (Karpenter uses Pod Identity, not IRSA)
aws eks list-pod-identity-associations --cluster-name simple-eks --region ap-south-1 \
  --namespace karpenter --service-account karpenter
```

## Root Causes

| Cause | How to Identify |
|---|---|
| NodePool `workload` resource limits hit | `kubectl describe nodepool workload` shows `limits.cpu/memory` exhausted |
| No matching instance types / AZ capacity | EC2 `InsufficientInstanceCapacity` in Karpenter logs |
| Pod Identity association missing or incorrect | `list-pod-identity-associations` returns empty; `AccessDenied` in logs |
| Subnet tags missing | Karpenter logs: `no subnets found` - needs both tags below |
| Security group tag missing | Karpenter logs: `no security groups found` |
| AMI alias stale | `InvalidAMIID` in logs; amiAlias `al2023@v20260415` no longer resolves |
| Pod missing `app=workload` toleration | `describe pod` shows taint mismatch - NodePool has `app=workload:NoSchedule` |
| Karpenter controller is not running | `kubectl get pods -n karpenter` shows 0/1 |
| Consolidation racing with scale-out | Karpenter deleting nodes while trying to provision - check logs |

## Fix

### NodePool limits exhausted
```bash
# Temporarily raise limits
kubectl edit nodepool workload
# Increase spec.limits.cpu and spec.limits.memory

# Permanently: update gitops/auto-scaling/karpenter/karpenter-nodepools.yaml
# under: spec.limits.cpu / spec.limits.memory and commit
```

### EC2 capacity unavailable in AZ
The NodePool currently uses `t3a.medium` and `c6a.large`. Add more families:
```yaml
# In karpenter-nodepools.yaml under spec.template.spec.requirements
- key: node.kubernetes.io/instance-type
  operator: In
  values: ["t3a.medium", "c6a.large", "c6i.large", "m6a.large", "m5a.large"]
```

### Pod Identity missing or broken
Karpenter uses EKS Pod Identity (not IRSA). The association is created by `terraform/karpenter.tf` via `create_pod_identity_association = true`.
```bash
# Verify the association
aws eks list-pod-identity-associations --cluster-name simple-eks \
  --namespace karpenter --service-account karpenter --region ap-south-1

# If missing, re-apply the Terraform module
cd terraform && terraform apply -target=module.karpenter
```

### Missing subnet/security group tags
Both tags are required for subnet selection:
- `karpenter.sh/discovery: simple-eks`
- `subnet-type: private`

```bash
# Check subnets have BOTH tags
aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=simple-eks" \
            "Name=tag:subnet-type,Values=private" \
  --region ap-south-1 --query 'Subnets[].SubnetId'

# If empty, enable tagging in Terraform:
# In terraform/variables.tf set enable_karpenter_discovery_tags = true
# terraform apply
```

### Pod missing `app=workload` toleration
The `workload` NodePool has a `app=workload:NoSchedule` taint. Any pod that should land on Karpenter nodes must declare:
```yaml
tolerations:
  - key: app
    operator: Equal
    value: workload
    effect: NoSchedule
nodeSelector:
  app: workload
```
This is already set in `gitops/app/simple-time-service/simple-time-service.yaml`. Check it hasn't been removed.

### Karpenter pod not running
```bash
kubectl rollout restart deployment karpenter -n karpenter
kubectl rollout status deployment karpenter -n karpenter
```

## Prevention

- Set NodePool limits generously for prod; configure a cost alert at 80% of the limit
- Keep `t3a.medium` + `c6a.large` as the baseline but add 2–3 alternative families to reduce single-AZ `InsufficientCapacity` risk
- Tag subnets and security groups via Terraform (`enable_karpenter_discovery_tags = true`) - both `karpenter.sh/discovery` and `subnet-type: private` are required
- Monitor `karpenter_nodes_allocatable` and `karpenter_provisioner_limit_*` in Grafana
- After any Terraform IAM/Pod Identity change, confirm the association exists with `aws eks list-pod-identity-associations`
