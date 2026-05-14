# Storage - AWS EBS CSI Driver

The `gitops/storage/` directory deploys the EBS CSI Driver via ArgoCD, which enables dynamic EBS volume provisioning for stateful workloads.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `ebs-csi-driver/ebs-csi-driver.yaml` | AWS EBS CSI Driver v2.32.0 - controller + node DaemonSet + `gp3` StorageClass | 1 | `kube-system` |

Runs at sync-wave 1 so the StorageClass exists before any stateful workload (Prometheus, Thanos, Alertmanager) attempts to create a PVC.

---

## Architecture

```
PVC created (e.g. Prometheus storageSpec)
    │
    ▼
kube-controller-manager detects unbound PVC
    │  StorageClass: gp3 (WaitForFirstConsumer)
    ▼
EBS CSI Controller (kube-system)
    │  calls AWS EC2 API via IRSA
    │  creates gp3 EBS volume in the same AZ as the pod
    ▼
EBS CSI Node DaemonSet
    │  attaches and mounts the volume to the node
    ▼
Pod receives mounted volume at the configured mountPath
```

`WaitForFirstConsumer` binding mode delays volume creation until the pod is scheduled, ensuring the EBS volume is always created in the same AZ as the pod.

---

## EBS CSI Driver

| Setting | Value |
|---------|-------|
| Chart | `aws-ebs-csi-driver` v2.32.0 (from `https://kubernetes-sigs.github.io/aws-ebs-csi-driver/`) |
| Controller nodes | core nodes (`app=core` nodeSelector + toleration) |
| Node DaemonSet | `tolerateAllTaints: true` - runs on every node regardless of taints |
| IRSA | `<cluster-name>-ebs-csi-controller-irsa` |

The IRSA role is provisioned by `terraform/ebs-csi-driver-irsa.tf` using the module's built-in `attach_ebs_csi_policy = true` flag, which attaches the AWS-managed `AmazonEBSCSIDriverPolicy`.

Verify the driver is running:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl get pods -n kube-system -l app=ebs-csi-node
```

---

## StorageClass

A single `gp3` StorageClass is created as the cluster default:

| Setting | Value | Notes |
|---------|-------|-------|
| Name | `gp3` | Default StorageClass for all PVCs |
| Volume type | `gp3` | Better baseline throughput and IOPS than `gp2` at same cost |
| Encrypted | `true` | All volumes encrypted at rest |
| Reclaim policy | `Retain` | Volumes are **not** deleted when a PVC is deleted - manual cleanup required |
| Volume binding | `WaitForFirstConsumer` | Volume created in the pod's AZ only after scheduling |
| Volume expansion | `true` | PVCs can be resized without downtime |

> **Retain policy** means that deleting a PVC leaves the underlying EBS volume in AWS. The `cleanup.sh` script handles deletion of these leftover volumes using the `kubernetes.io/cluster/<cluster>=owned` tag.

Verify the StorageClass is set as default:

```bash
kubectl get storageclass
# gp3 should show "(default)" in the NAME column
```

---

## PVC inventory

These PVCs are created automatically when their respective apps sync:

| Workload | Namespace | Size | Purpose |
|----------|-----------|------|---------|
| Prometheus | `monitoring` | 20Gi | TSDB local retention (7 days) |
| Alertmanager | `monitoring` | 2Gi | Silence and notification state |
| Thanos Compactor | `monitoring` | 10Gi | Temporary workspace for block compaction |
| Thanos StoreGateway | `monitoring` | 5Gi | Index cache for S3-backed historical blocks |

Check all PVCs and their binding status:

```bash
kubectl get pvc -n monitoring
kubectl get pv
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| PVC stuck in `Pending` | Check CSI controller logs: `kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner`. Confirm the IRSA role ARN is correct on the controller service account: `kubectl get sa ebs-csi-controller-sa -n kube-system -o yaml`. |
| `StorageClass "gp3" not found` | The EBS CSI Driver app may not have synced yet. Check ArgoCD: `kubectl get app aws-ebs-csi-driver -n argocd`. |
| Volume stuck in `Attaching` | The EBS volume may be in a different AZ than the pod. `WaitForFirstConsumer` prevents this for new PVCs, but an existing volume cannot be moved. Delete the PVC and PV and let them be recreated. |
| Volume not deleted after PVC deletion | Expected - `Retain` policy. To delete manually: `aws ec2 delete-volume --volume-id <vol-id> --region <region>`. |
