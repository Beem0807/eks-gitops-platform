# EBS PVC Not Mounting / Pod Stuck in ContainerCreating

## Symptoms

- Pod stuck in `ContainerCreating` for > 2 minutes
- `kubectl describe pod <name>` shows event: `AttachVolume.Attach failed` or `Multi-Attach error`
- `kubectl describe pvc <name>` shows `Bound` but pod still can't start
- Pod was rescheduled to a different node (e.g., after a node replacement by Karpenter)
- EBS CSI driver node pod is missing on the target node

## Impact

- **High**: The affected pod cannot start until the volume is attached - this blocks stateful platform components
- If it affects Prometheus, Alertmanager, or Thanos, observability and alerting are degraded

## Quick Checks

```bash
# Which pod and PVC are involved?
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <pod-name> -n <namespace> | grep -A 15 "Events:"

# What does the PVC say?
kubectl describe pvc <pvc-name> -n <namespace>

# What node is the pod trying to schedule on, and what AZ is it in?
kubectl get pod <pod-name> -n <namespace> -o wide
aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=<node-internal-dns>" \
  --query 'Reservations[].Instances[].Placement.AvailabilityZone' \
  --region <region>

# What AZ is the EBS volume in?
kubectl get pv <pv-name> -o jsonpath='{.spec.nodeAffinity}'

# Is the EBS CSI driver node DaemonSet running on every node?
kubectl get pods -n kube-system -l app=ebs-csi-node -o wide

# EBS CSI controller logs
kubectl logs -n kube-system \
  -l app=ebs-csi-controller -c csi-provisioner --tail=100
```

## Root Causes

| Cause | How to Identify |
|---|---|
| Pod rescheduled to a different AZ than the EBS volume | Pod AZ ≠ PV node affinity AZ |
| `Multi-Attach error` - volume still attached to old node | Previous node not yet terminated; EBS allows one attachment at a time |
| EBS CSI node DaemonSet pod missing on target node | `kubectl get pods -n kube-system -l app=ebs-csi-node -o wide` - node not listed |
| IRSA role missing `ec2:AttachVolume` | CSI controller logs show `AccessDenied` |
| EBS volume deleted manually | PVC shows `Lost`; PV shows `Released` |

## Platform Components with PVCs

> **This platform**: The following components use `gp3` EBS volumes via the default storage class. All are in the `monitoring` namespace.

| Component | PVC size | StatefulSet / Pod |
|---|---|---|
| Prometheus | 20 Gi | `prometheus-kube-prometheus-prometheus-0` |
| Alertmanager | 2 Gi | `alertmanager-kube-prometheus-alertmanager-0` |
| Thanos StoreGateway | 5 Gi | `thanos-storegateway-0` |
| Thanos Compactor | 10 Gi | `thanos-compactor-0` |

## Fix

### AZ mismatch - volume in different AZ than node
EBS volumes are AZ-bound. If a pod is rescheduled to a different AZ, it cannot attach the volume.

**Option 1: Force the pod back to the original AZ**
```bash
# Find the AZ the PV is locked to
kubectl get pv <pv-name> \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms}'

# Delete the pod so it reschedules - Kubernetes will honour the PV's AZ topology
kubectl delete pod <pod-name> -n <namespace>
# If Karpenter provisioned a node in the wrong AZ, it will provision a new one in the correct AZ
```

**Option 2: If you need the pod in a specific AZ permanently**
Add a `nodeAffinity` or `nodeSelector` to the StatefulSet/PodSpec to pin it to the correct AZ. For platform components, update the HelmRelease values in the relevant GitOps file and commit.

### Multi-Attach error (old node not yet terminated)
```bash
# Check if the previous node still exists
kubectl get nodes

# If the node is in NotReady/terminating state, force-delete the pod to release the attachment
kubectl delete pod <pod-name> -n <namespace> --grace-period=0 --force

# If the node is gone but volume is still attached in AWS, detach it
aws ec2 describe-volumes --volume-ids <vol-id> --region <region> \
  --query 'Volumes[].Attachments'
aws ec2 detach-volume --volume-id <vol-id> --force --region <region>
```

### EBS CSI node pod missing on target node
The node DaemonSet has `tolerations: - operator: "Exists"` so it should run on all nodes including Karpenter ones.
```bash
# Check if the DaemonSet is healthy
kubectl rollout status daemonset ebs-csi-node -n kube-system

# If a new node came up and the pod hasn't started yet, wait ~30s or describe the DaemonSet
kubectl describe daemonset ebs-csi-node -n kube-system
```

### IRSA role missing EC2 permissions
```bash
# Verify IRSA annotation on the CSI controller service account
kubectl get sa ebs-csi-controller-sa -n kube-system \
  -o jsonpath='{.metadata.annotations}'

# If the role is missing actions, re-apply
# File: gitops/storage/ebs-csi-driver/ebs-csi-driver.yaml (IRSA role annotation)
# and the corresponding Terraform IRSA module
```

## Prevention

- Use `topologySpreadConstraints` or `nodeAffinity` on StatefulSets that use EBS to pin them to a single AZ - avoids AZ rescheduling surprises
- Monitor `kubelet_volume_stats_available_bytes` per PVC to catch disks filling up before they cause mount issues
- When replacing nodes intentionally (e.g., AMI upgrade), drain gracefully so StatefulSet pods terminate cleanly before the EBS volume is detached
- gp3 storage class is encrypted by default in this platform (`terraform/ebs-csi-driver` via the Helm chart config) - no action needed there
