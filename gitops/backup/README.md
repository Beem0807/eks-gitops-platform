# Backup and Restore - Velero

The `gitops/backup/` directory deploys Velero via ArgoCD, providing cluster-level backup and restore for both Kubernetes resources and EBS volumes.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `velero/velero.yaml` | Velero v8.1.0 + AWS plugin v1.10.0 - backup controller, BackupStorageLocation (S3), VolumeSnapshotLocation (EBS) | 3 | `velero` |
| `velero/velero-schedule.yaml` | Velero `Schedule` resource - daily full-cluster backup at 02:00 UTC, 30-day retention | 5 | `velero` |

---

## Architecture

```
Velero controller (velero namespace)
    │  scheduled or on-demand backup triggered
    ▼
Kubernetes API
    │  serialises all resources (Deployments, PVCs, Secrets, etc.)
    ▼
S3 bucket: <cluster-name>-velero-backups-<account-id>-<region>
    │  Kubernetes manifests stored as compressed tarballs
    ▼
EBS Snapshot (via velero-plugin-for-aws)
    │  point-in-time snapshot of each PVC's EBS volume
    ▼
AWS EC2 Snapshots (same region)
```

Restoring from a backup reverses the flow: Velero re-applies the serialised manifests to the cluster and creates new EBS volumes from the snapshots, then rebinds PVCs to the new volumes.

---

## Velero

| Setting | Value |
|---------|-------|
| Chart | `velero` v8.1.0 (from `https://vmware-tanzu.github.io/helm-charts`) |
| AWS plugin | `velero/velero-plugin-for-aws:v1.10.0` |
| Credentials | IRSA — no static AWS credentials in the cluster |
| IRSA | `<cluster-name>-velero-irsa` |
| BackupStorageLocation | S3 bucket `<cluster-name>-velero-backups-<account-id>-<region>` |
| VolumeSnapshotLocation | EBS snapshots in the same region as the cluster |
| Controller nodes | core nodes (`app=core` nodeSelector + toleration) |
| Metrics | ServiceMonitor enabled — Velero metrics scraped by Prometheus |

The IRSA role is provisioned by `terraform/velero.tf` and grants S3 read/write/delete on the backup bucket plus EC2 snapshot permissions (`CreateSnapshot`, `DeleteSnapshot`, `DescribeSnapshots`, `DescribeVolumes`, `CreateTags`).

The bucket name is injected into the ArgoCD cluster secret as `velero-bucket-name` by `bootstrap.sh`/`upgrade.sh` and resolved into the ApplicationSet via the cluster generator `veleroBucketName` value — no hardcoded bucket names in the manifest.

Verify Velero is running and the backup location is reachable:

```bash
kubectl get pods -n velero
kubectl get backupstoragelocation -n velero
# PHASE should be: Available
```

---

## Creating a backup

```bash
# On-demand backup of all namespaces
velero backup create full-backup --wait

# Backup specific namespaces only
velero backup create monitoring-backup \
  --include-namespaces monitoring,logging \
  --wait

# Check backup status
velero backup describe full-backup
velero backup logs full-backup
```

---

## Restoring from a backup

```bash
# List available backups
velero backup get

# Restore all resources from a backup
velero restore create --from-backup full-backup --wait

# Restore specific namespaces only
velero restore create --from-backup full-backup \
  --include-namespaces monitoring \
  --wait

# Check restore status
velero restore describe <restore-name>
velero restore logs <restore-name>
```

---

## Scheduled backup

A `Schedule` named `daily-backup` is deployed automatically via `velero/velero-schedule.yaml` (sync-wave 5, after Velero at wave 3 is running). It runs every day at **02:00 UTC** and backs up all namespaces and cluster-scoped resources, with a **30-day TTL**.

| Setting | Value |
|---------|-------|
| Schedule | `0 2 * * *` (02:00 UTC daily) |
| Scope | All namespaces + cluster-scoped resources |
| Volume snapshots | Enabled (`storageLocation: default`) |
| Retention (TTL) | 720h (30 days) |

```bash
# Check the schedule is active
kubectl get schedule -n velero

# List backups taken so far
velero backup get
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `BackupStorageLocation` phase `Unavailable` | Check IRSA: `kubectl get sa velero -n velero -o yaml` — confirm the `eks.amazonaws.com/role-arn` annotation. Check controller logs: `kubectl logs -n velero -l app.kubernetes.io/name=velero`. |
| Backup stuck in `InProgress` | Check logs: `velero backup logs <backup-name>`. Common cause: IRSA permissions missing for EC2 snapshot actions. |
| PVC not included in backup | Velero backs up PVC objects but skips volume snapshots for PVCs annotated with `backup.velero.io/backup-volumes-excludes`. Remove the annotation or explicitly include the volume: `--include-volumes`. |
| Restore fails with `already exists` | Add `--existing-resource-policy update` to the restore command to patch existing resources rather than fail. |
| EBS snapshot not deleted after backup TTL | The `cleanup.sh` script deletes all snapshots tagged `velero.io/backup` as a safety net during cluster teardown. For production, ensure Velero's GC is running: `kubectl get pods -n velero -l app.kubernetes.io/name=velero`. |
| `velero-upgrade-crds` job stuck in `ImagePullBackOff` | The chart derives the `bitnami/kubectl` tag from the cluster's Kubernetes version, but Bitnami no longer publishes version-specific tags to Docker Hub. Fixed by pinning `kubectl.image.tag: "latest"` in `velero.yaml`. |
