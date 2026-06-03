# Security

Documents every security control implemented in this platform and what remains to be hardened for production use.

---

## Implemented controls

### IAM - IRSA for every workload

No workload uses a node-level IAM role for AWS API access. Every component that calls AWS APIs has a dedicated IRSA role scoped to exactly what it needs.

| Service account | Namespace | Permissions |
|----------------|-----------|-------------|
| `external-secrets` | `external-secrets` | `GetSecretValue`, `DescribeSecret` - scoped to secrets tagged `ExternalSecret=true` only |
| `ebs-csi-controller-sa` | `kube-system` | AWS managed EBS CSI policy |
| `aws-load-balancer-controller` | `kube-system` | Official AWS LBC policy (upstream-maintained) |
| `cluster-autoscaler` | `kube-system` | `SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup` scoped by cluster tags; describe operations are broad (AWS does not support resource ARNs for these) |
| `external-dns` | `external-dns` | `ChangeResourceRecordSets` scoped to hosted zone; list operations are broad (unavoidable in AWS) |
| `loki` | `logging` | S3 `GetObject`, `PutObject`, `DeleteObject` - Loki bucket only |
| `prometheus` | `monitoring` | S3 read/write - Thanos bucket only (sidecar ship path) |
| `thanos-compactor`, `thanos-storegateway` | `monitoring` | S3 read/write - Thanos bucket only |
| `velero` | `velero` | S3 access on Velero bucket; `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:Describe*` (AWS does not support resource ARNs for snapshot operations) |
| `karpenter` | `karpenter` | Pod Identity Association - newer mechanism, no OIDC annotation required |

Inline Checkov skips (`CKV_AWS_111`, `CKV_AWS_356`) document the two IAM policies where AWS does not support resource-level ARNs.

---

### Network

- **Node placement:** All worker nodes run in private subnets. Only the NAT Gateway and ALBs are in public subnets.
- **Single NAT Gateway:** One NAT Gateway shared across both AZs - reduces cost; a production deployment would use one per AZ.
- **HTTPS everywhere:** All ALB ingresses enforce HTTPS with HTTP → HTTPS redirect. TLS terminates at the ALB.
- **Restricted ingress exposure:**

| Workload | Access method |
|----------|--------------|
| ArgoCD | Public ALB - HTTPS, password-protected |
| Grafana | Public ALB - HTTPS, password-protected |
| SimpleTimeService | Public ALB - HTTPS |
| Prometheus | `kubectl port-forward` only - no ingress |
| Alertmanager | `kubectl port-forward` only - no ingress |
| Policy Reporter | `kubectl port-forward` only - no ingress |

- **EKS API endpoint:** Public endpoint enabled. No private endpoint or CIDR allowlist - see [Production Hardening](#production-hardening) below.

---

### Secrets

No credentials or secret values are committed to git. All secrets follow the same path:

```
AWS Secrets Manager → External Secrets Operator → Kubernetes Secret → Pod
```

- **AWS Secrets Manager** stores all credentials (ArgoCD admin password, Grafana admin, Slack webhook URL).
- **ExternalSecretOperator** (chart `0.10.7`) runs with an IRSA role that can only read secrets tagged `ExternalSecret=true`.
- **ClusterSecretStore** uses JWT auth via the ESO service account annotation - no static AWS credentials in the cluster.
- **Reloader** watches Secrets and ConfigMaps and triggers rolling restarts when ESO refreshes a value (every 1 hour), ensuring workloads always use the current secret without manual intervention.

---

### Container and pod security

The SimpleTimeService container and its pod spec apply the following controls:

**Dockerfile (`app/Dockerfile`):**
- Base image: `python:3.12-slim`
- Non-root user created at build time: UID `10001`, GID `10001`
- App files owned by `appuser`; runs as `USER 10001:10001`
- No pip cache, no root-owned artifacts

**Pod security context (`charts/simple-time-service/values.yaml`):**
```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

**Resource limits:**
```yaml
requests:
  cpu: 100m
  memory: 128Mi
limits:
  cpu: 250m
  memory: 256Mi
```

---

### Admission control - Kyverno

Kyverno (chart `3.2.7`) runs as an admission controller. Four `ClusterPolicy` rules evaluate every pod admission:

| Policy | What it checks | Mode |
|--------|---------------|------|
| Require resource limits | CPU and memory limits must be set on all containers | Audit |
| Disallow privileged containers | `privileged: true` is rejected (exempts `kube-system`, `karpenter`) | Audit |
| Disallow `:latest` tag | Images must have an explicit tag that is not `:latest` | Audit |
| Require run as non-root | Pod or container must set `runAsNonRoot: true` | Audit |

All policies run in **Audit** mode - violations are recorded in `PolicyReport` objects and visible in Policy Reporter but do not block deployment. Switching to Enforce mode is tracked in [Production Hardening](#production-hardening).

Policy Reporter (chart `2.24.1`) provides a web UI for browsing policy violations across all namespaces.

---

### S3 bucket security

Three buckets store observability data and backups. All share the same baseline controls:

| Control | Loki | Thanos | Velero |
|---------|------|--------|--------|
| Encryption | SSE-S3 (AES-256) | SSE-S3 (AES-256) | SSE-S3 (AES-256) |
| Versioning | Enabled | Enabled | Enabled |
| Public access block | All four flags enabled | All four flags enabled | All four flags enabled |
| Access logging | Disabled | Disabled | Disabled |
| Static credentials | None - IRSA only | None - IRSA only | None - IRSA only |

SSE-KMS and access logging are intentionally deferred for a personal demo environment. Both are tracked in [Production Hardening](#production-hardening). The rationale for each skipped Checkov check is documented in `terraform/.checkov.yaml`.

---

### ArgoCD - AppProjects and RBAC

Every ArgoCD application belongs to an AppProject that restricts what it can deploy:

| Project | Destination namespaces | Cluster-scoped resources |
|---------|----------------------|--------------------------|
| `workloads` | `simple-time-service` only | None - `clusterResourceWhitelist: []` |
| `security` | `security` only | CRDs, ClusterRoles, webhook configs, ClusterPolicies |
| `platform` | `argocd`, `kube-system`, `karpenter`, `external-secrets`, `external-dns`, `reloader`, `velero`, `kube-node-lease` | Unrestricted - required for infrastructure components |
| `observability` | `monitoring`, `logging` | CRDs, ClusterRoles for Prometheus operator |

The `workloads` project has an empty `clusterResourceWhitelist` - application developers cannot deploy `ClusterRole`, `CRD`, or any cluster-scoped resource through ArgoCD.

---

### CI/CD and supply chain

| Control | Tool | What it does |
|---------|------|-------------|
| Container vulnerability scan | Trivy (`aquasecurity/trivy-action@v0.36.0`) | Scans image for CRITICAL and HIGH CVEs; ignores unfixed; blocks merge on findings; uploads SARIF to GitHub Security tab |
| IaC security scan | Checkov | Scans Terraform for misconfigurations; uploads SARIF to GitHub Security tab; all skips documented with rationale |
| Workflow linting | actionlint | Validates all GitHub Actions workflow files for syntax and expression errors |
| Kubernetes manifest validation | kubeconform | Validates rendered Helm charts and raw manifests against Kubernetes 1.34 schema |
| YAML linting | yamllint | Enforces consistent YAML style across `gitops/`, `k8s/`, `charts/` |
| CODEOWNERS | `.github/CODEOWNERS` | All paths owned by `@Beem0807`; changes to any directory require review |
| Branch protection | `.github/branch-protection.md` | All CI checks must pass; direct pushes to `main` blocked |
| Image tagging | Docker Buildx | Short SHA tag is always pushed (immutable); `:latest` pushed on merge to `main` only |

---

### Backup

Velero runs a daily backup schedule at `02:00 UTC`:
- **Scope:** All namespaces + cluster-scoped resources
- **Volume snapshots:** EBS snapshots included
- **Retention:** 30 days
- **Storage:** Dedicated S3 bucket (`velero-backups-{account_id}-{region}`)
- **Credentials:** IRSA - no static AWS credentials in the cluster

Velero exposes metrics that are scraped by Prometheus and visible in Grafana.

---

## Production hardening

Controls that are intentionally deferred for a personal demo environment. These are the items that would need to change before running this platform in production.

### Network

| Item | Current state | What to do |
|------|--------------|------------|
| EKS API server endpoint | Public, accessible from `0.0.0.0/0` | Enable private endpoint; restrict or disable the public endpoint |
| API server CIDR allowlist | None | Restrict to known CIDRs (VPN, office, CI runner IPs) |
| Grafana ingress | Public ALB, password auth | Restrict ALB to internal CIDR or place behind VPN |
| NAT Gateway | Single (one AZ) | One NAT Gateway per AZ for HA |

### Encryption

| Item | Current state | What to do |
|------|--------------|------------|
| Kubernetes etcd secrets | Not envelope-encrypted | Enable `cluster_encryption_config` in the EKS module with a dedicated KMS CMK |
| S3 buckets (Loki, Thanos, Velero) | SSE-S3 (AES-256) | Replace with SSE-KMS using a CMK per bucket with rotation enabled |
| Secrets Manager | AWS-managed key | Encrypt with a customer-managed KMS key |
| EBS volumes (Prometheus, Thanos) | AWS-managed default encryption | Encrypt with a customer-managed KMS key |

### Secrets

| Item | Current state | What to do |
|------|--------------|------------|
| Secrets Manager rotation | Disabled | Enable automatic rotation with a Lambda rotator for credentials that support it |
| S3 access logging | Disabled | Enable access logging on all three buckets to a dedicated log bucket |

### Observability

| Item | Current state | What to do |
|------|--------------|------------|
| Grafana authentication | Built-in username/password | Integrate OIDC/SSO (Google Workspace, Okta, AWS IAM Identity Center) |
| Loki deployment mode | Monolithic single binary | Migrate to `SimpleScalable` (read/write split) or distributed mode for production throughput and durability |

### Security policy

| Item | Current state | What to do |
|------|--------------|------------|
| Kyverno policy mode | Audit - violations logged, not blocked | Migrate critical policies (disallow `:latest`, require limits, disallow privileged) to `Enforce` |
| Image references | Tags (`:1.2.3`, short SHA) | Pin all third-party images to immutable digests (`image@sha256:…`) to prevent tag mutation |
| NetworkPolicy | Defined but disabled by default | Enable NetworkPolicy on all workloads; restrict ingress/egress to known namespaces and ports |

### Reliability

| Item | Current state | What to do |
|------|--------------|------------|
| Velero restore testing | Backups run, restores untested | Schedule periodic restore drills; validate application state post-restore |
| Control plane AZ coverage | EKS control plane is multi-AZ by default | Ensure managed node group and Karpenter NodePools span at least 3 AZs |
| StatefulSet replicas | Single replica (Prometheus, Thanos components) | Run 2+ replicas for Prometheus and Thanos Query; use Thanos Ruler for HA alerting |
| ALB target redundancy | Single pod per service | Set `minReplicas ≥ 2` on HPA for all user-facing workloads; add PodDisruptionBudgets |
