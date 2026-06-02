# Runbooks

Operational runbooks for the EKS GitOps platform. Each runbook covers a specific failure scenario with symptoms, impact, quick checks, root causes, fix steps, and prevention.

All runbooks follow the **generic + project callout** convention: diagnostic steps work for any EKS platform, and `> **This platform**:` blocks call out decisions specific to this setup (e.g. Pod Identity instead of IRSA for Karpenter, Thanos as the Grafana datasource, `notify: slack` label requirement for Alertmanager routing).

---

## Index

### Compute & Scheduling

| Runbook | When to use |
|---------|-------------|
| [karpenter-node-not-provisioning.md](karpenter-node-not-provisioning.md) | Pods stuck `Pending`, Karpenter not launching EC2 instances |
| [hpa-not-scaling.md](hpa-not-scaling.md) | HPA shows `<unknown>` targets or replica count not growing under load |
| [ebs-pvc-not-mounting.md](ebs-pvc-not-mounting.md) | Pod stuck in `ContainerCreating`, AZ mismatch, `Multi-Attach error` |

### Networking & DNS

| Runbook | When to use |
|---------|-------------|
| [alb-503.md](alb-503.md) | ALB returning 503, no healthy targets, LB controller issues |
| [externaldns-not-creating-record.md](externaldns-not-creating-record.md) | DNS record missing in Route53 after deploy |

### GitOps

| Runbook | When to use |
|---------|-------------|
| [argocd-outofsync.md](argocd-outofsync.md) | ArgoCD app shows `OutOfSync` or `Degraded` |

### Observability

| Runbook | When to use |
|---------|-------------|
| [prometheus-target-down.md](prometheus-target-down.md) | `TargetDown` alert, Grafana gaps, `up{job="..."}` returns 0 |
| [thanos-no-metrics.md](thanos-no-metrics.md) | Grafana "No data" across all dashboards (Prometheus healthy, Thanos broken) |
| [loki-no-logs.md](loki-no-logs.md) | Loki returns empty, Fluent Bit errors, logs absent in Grafana |
| [alertmanager-not-firing.md](alertmanager-not-firing.md) | Alert firing in Prometheus but no Slack message received |

### Secrets & Config

| Runbook | When to use |
|---------|-------------|
| [external-secrets-not-syncing.md](external-secrets-not-syncing.md) | ExternalSecret in `SecretSyncedError`, pod failing due to missing secret |

### Security

| Runbook | When to use |
|---------|-------------|
| [kyverno-policy-violation.md](kyverno-policy-violation.md) | Policy violations in Policy Reporter, deployment blocked by admission webhook |

### Backup & Restore

| Runbook | When to use |
|---------|-------------|
| [velero-restore.md](velero-restore.md) | Recovering from data loss - namespace, PVC, selective resource, or full DR restore |
