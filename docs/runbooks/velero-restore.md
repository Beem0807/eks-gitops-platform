# Velero Backup Restore

## Symptoms

- Namespace, PVC data, or cluster resources lost (accidental deletion, botched migration, cluster rebuild)
- Need to recover specific resources after a failed deployment or data corruption
- DR drill: validating restore procedure before an actual incident
- `velero backup get` shows recent backups in `Completed` state

## Impact

- Restore is a planned recovery procedure - execute when data loss is confirmed
- Partial restores can be done without cluster-wide impact
- Full namespace or cluster restores require downtime planning

## Quick Checks

```bash
# List available backups
velero backup get
# or
kubectl get backup -n velero

# Get details on a specific backup
velero backup describe <backup-name> --details

# Check backup logs for completeness
velero backup logs <backup-name>

# Velero pod status
kubectl get pods -n velero -l app.kubernetes.io/name=velero

# Verify BackupStorageLocation is available
kubectl get backupstoragelocation -n velero

# Confirm S3 bucket contains backup files
aws s3 ls s3://<velero-bucket-name>/backups/ --region <region>
```

> **This platform**: The scheduled backup is named `daily-backup`. It runs at `0 2 * * *` (02:00 UTC), backs up **all namespaces** with cluster resources included, and has a TTL of **720h (30 days)**. Defined in `gitops/backup/velero/velero-schedule.yaml`.
>
> S3 bucket name: `<cluster-name>-velero-backups-<account-id>-<region>` (from `terraform/velero.tf`).

## Restore Scenarios

| Scenario | Approach |
|---|---|
| Namespace accidentally deleted | Full namespace restore from latest backup |
| Single resource deleted/corrupted | Selective restore with `--include-resources` |
| PVC data loss | PVC-only restore, then scale workload back up |
| Cluster rebuild / DR failover | Full cluster restore into new cluster |

## Fix

### Restore a full namespace
```bash
# Find the most recent successful backup
velero backup get | grep Completed | sort -k5 | tail -5

# Restore (dry run first to preview)
velero restore create --from-backup <backup-name> \
  --include-namespaces <namespace> \
  --wait

# Monitor progress
velero restore get
velero restore describe <restore-name> --details

# Check for partial failures
velero restore logs <restore-name>
```

### Restore a single resource type
```bash
velero restore create --from-backup <backup-name> \
  --include-namespaces <namespace> \
  --include-resources deployments,configmaps,secrets \
  --wait
```

### Restore a PVC (data recovery)
```bash
# 1. Scale down the workload to detach the PVC
kubectl scale deployment <name> -n <namespace> --replicas=0

# 2. Delete the corrupted PVC (Velero will recreate it)
kubectl delete pvc <pvc-name> -n <namespace>

# 3. Restore only the PVC
velero restore create --from-backup <backup-name> \
  --include-namespaces <namespace> \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --wait

# 4. Scale the workload back up
kubectl scale deployment <name> -n <namespace> --replicas=<original>
```

### Restore into a different namespace (safe preview)
```bash
velero restore create --from-backup <backup-name> \
  --include-namespaces <source-namespace> \
  --namespace-mappings <source-namespace>:<target-namespace> \
  --wait

# Inspect, then delete if no longer needed
kubectl get all -n <target-namespace>
```

### Full cluster restore (DR scenario)
```bash
# On the new cluster - Velero must already be installed and pointing at the same S3 bucket

# 1. Verify the BackupStorageLocation is Available
velero backup-location get

# 2. Restore all namespaces except platform-managed ones
velero restore create --from-backup <backup-name> \
  --exclude-namespaces kube-system,velero,kube-public,argocd \
  --wait

# 3. Let ArgoCD re-sync the platform components from Git
argocd app list
```

### Velero can't read backups (S3 access issue)
```bash
kubectl describe backupstoragelocation default -n velero

# Verify IRSA annotation
kubectl get sa velero -n velero -o jsonpath='{.metadata.annotations}'

# Test bucket access
aws s3 ls s3://<velero-bucket-name>/ --region <region>
```

> **This platform**: IRSA role follows pattern `<cluster-name>-velero-irsa`. The IAM policy grants S3 object access and EC2 snapshot permissions (for EBS volume snapshots). If access is denied, re-apply `terraform/velero.tf`:
```bash
cd terraform && terraform apply -target=module.velero_irsa
```

## Prevention

- Alert on `velero_backup_last_successful_timestamp` being older than 25 hours
- Alert on backup status `PartiallyFailed` or `Failed` - do not let silently broken backups accumulate
- Run a restore drill quarterly into a scratch namespace to confirm backups are actually usable
- Keep Velero's S3 bucket protected - the bucket has versioning and public access block enabled (`terraform/velero.tf`); do not disable these

---
**Restore drill log** _(update after each drill)_

| Date | Backup used | Scope | RTO | Outcome |
|---|---|---|---|---|
| | | | | |
