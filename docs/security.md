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
| `tempo` | `tracing` | S3 `GetObject`, `PutObject`, `DeleteObject` - Tempo bucket only |
| `karpenter` | `karpenter` | Pod Identity Association - newer mechanism, no OIDC annotation required |

Inline Checkov skips (`CKV_AWS_111`, `CKV_AWS_356`) document the two IAM policies where AWS does not support resource-level ARNs.

---

### IAM - Crossplane provider roles

The Crossplane AWS providers use **EKS Pod Identity** rather than IRSA, because their ServiceAccounts are created by the Crossplane package manager rather than by Helm and so have nowhere to carry an IRSA annotation. Each provider pod gets its own role.

| Service account | Namespace | Permissions |
|----------------|-----------|-------------|
| `provider-aws-s3` | `crossplane-system` | S3 bucket lifecycle and configuration, account-wide; object delete for `forceDestroy`. No ECR, SQS, or any other service |
| `provider-aws-ecr` | `crossplane-system` | ECR repository lifecycle, policies, and image delete, in one region |
| `provider-aws-sqs` | `crossplane-system` | SQS queue lifecycle and attributes, in one region |
| `provider-aws-cloudwatchevents` | `crossplane-system` | EventBridge rule and target lifecycle, in one region |
| `provider-aws-family` | `crossplane-system` | None - serves the credential types only and makes no AWS calls |

---

### IAM - workload and CI roles

Crossplane's roles are a control plane; these are the data-plane identities that
use what it provisions. Both are IRSA rather than Pod Identity, because a Pod
Identity association is an exact namespace/ServiceAccount pair and cannot
wildcard a namespace.

| Role | Trust | Permissions |
|------|-------|-------------|
| `<cluster>-mlops-pipeline` | `StringLike system:serviceaccount:` on `mlops-system:*`, `kubeflow:*` | S3 **read/write** and SQS data-plane actions, conditioned on `Workload=mlops` |
| `<cluster>-mlops-serving` | `StringLike system:serviceaccount:mlops:*` | S3 read (`GetObject`, `ListBucket`) plus **one** write: `s3:PutObject` scoped to `*/observations/*`. All conditioned on `Workload=mlops`. No delete, no ACL, no multipart abort |
| `<cluster>-arc-runner` | Exact: `arc-runners:arc-runner` | ECR push and pull, plus `ecr:GetAuthorizationToken` |

The MLOps policy names **no resources**. Terraform cannot reference a bucket
Crossplane has not created yet, and every S3, SQS, and ECR data-plane action
supports tag conditions - for S3, `s3:BucketTag` applies to object-level actions
as well as bucket-level ones, which is what makes a tag-scoped object policy
possible. Tagging a Crossplane-provisioned bucket `Workload=mlops` is therefore
what grants access to it.

That makes a tag load-bearing for authorisation. Whoever can set tags on a
Crossplane resource can bring it into this role's scope. Nothing enforces the
tag, so a resource created without it is simply unreadable - `AccessDenied`,
which is the safe direction to fail.

**The serving role is no longer strictly read-only, and that is deliberate.**
KServe v0.21's inference logger writes batched parquet payload logs to S3 from
*inside the predictor pod*, so it carries this role; without a write it fails
every upload and drift detection has nothing to compare production traffic
against. The grant is one action, restricted by resource pattern to the
`observations/` prefix and still gated on the bucket tag, and the buckets are
versioned so even an overwrite retains the prior version.

What it costs: a compromised predictor can append objects under its own log
prefix. It still cannot read or write a model artifact, a dataset, or anything
outside that prefix. The alternative — a receiver service holding the pipeline
role — keeps the predictor pure at the cost of a component in the prediction
path, and was rejected on that basis. See design decision 32.

**Read/write is split from read-only, and the split falls on a namespace
boundary.** `mlops` is the serving namespace; `mlops-system` and `kubeflow` are
platform and pipelines. The KServe predictor runs model code and serves external
inference requests, making it the most exposed workload in the platform, and all
it needs is to download one model artifact. Under a single shared role it would
also hold `s3:DeleteObject` on the dataset bucket - so a compromised predictor
could delete every dataset. It now holds no write action whatsoever.

Deliberately not split further - no role per component. That would need
per-ServiceAccount trust policies, which reintroduces the problem IRSA was
chosen to avoid: Kubeflow Pipelines alone creates **16** ServiceAccounts whose
names change between releases, and each would require a Terraform change in this
repository. Read/write versus read-only is where the risk reduction is.

The namespace wildcard means any pod in a listed namespace *may* assume the
role - namespace-level, not service-account-level granularity. Note that the
trust policy is only permission to assume; the actual grant is the
`eks.amazonaws.com/role-arn` annotation on a ServiceAccount, so a pod whose
ServiceAccount carries no annotation receives no credentials. That keeps the
opt-in in the consuming repository.

`kubeflow` is a separate namespace because Kubeflow Pipelines' upstream overlay
hardcodes it. KFP reaches S3 through the AWS SDK default credential chain, which
is what avoids static access keys in a Secret. Appropriate for a single-team namespace; switch to exact service
account names if those namespaces ever host more than one team.

The runner role uses exact-ServiceAccount trust precisely because `arc-runners`
is shared infrastructure, where a new identity should require a deliberate
change.

Three separate identities are involved in getting an image into a pod, and none
can do another's job: `arc-runner` **pushes** to ECR, the Karpenter node role
**pulls**, and `provider-aws-ecr` **creates repositories** and cannot push.

Each role is confined to **one AWS service**. None of the three can reach IAM, EC2, RDS, or anything else, so a compromised provider cannot create a role or an instance.

Within its own service, each role is allowed account-wide. This is deliberate and the reasoning is in [design decision #24](design-decisions.md#24-eks-pod-identity-for-crossplane-and-deny-based-iam-scoping): consuming projects choose their own resource names, and a tag condition without an enforcement layer fails in a way that leaves resources unmanageable.

**Everything Terraform provisions is explicitly denied.** Terraform stamps `CrossplaneAccess=deny` on the Thanos, Loki, Velero, and Tempo buckets and the Karpenter interruption queue, and each policy carries a matching `Deny` statement. An explicit deny in IAM cannot be overridden by any allow, so no Crossplane manifest can delete the metric store, the log store, the backup bucket, the trace store, or the queue Karpenter needs for spot interruption handling.

The S3 deny is keyed on `s3:BucketTag` rather than `aws:ResourceTag` because, unlike `aws:ResourceTag`, it also applies to object-level actions - without that, `forceDestroy` could still empty a protected bucket.

Protecting a new Terraform-created bucket or queue is a one-line change: merge `local.crossplane_denied_tags` into its tags.

---

### IAM - KEDA operator

| Role | Trust | Permissions |
|------|-------|-------------|
| `<cluster>-keda-operator` | EKS Pod Identity on `keda:keda-operator` | `sqs:GetQueueAttributes` on **two named queue ARNs**, nothing else |

KEDA reads an external metric to decide whether to scale, which for an SQS
trigger means reading queue depth. The role is scoped to the specific queues
rather than `arn:aws:sqs:*:*:*` on purpose: a wildcard would let anything that
can run a pod in the `keda` namespace enumerate the depth of every queue in the
account, which is a cheap reconnaissance primitive.

`TriggerAuthentication` uses `podIdentity: {provider: aws}` with no `roleArn`,
so KEDA uses the operator's own identity. `identityOwner: workload` would make
it use the consuming namespace's ServiceAccount instead — which would mean
queue-depth reads depending on the broad pipeline role rather than one that can
only count messages.

### Crossplane API surface

Crossplane 2.x serves a provider's managed resource CRDs only when a `ManagedResourceActivationPolicy` names them, and this platform activates three API groups out of the roughly 2,100 types the AWS provider family ships:

```
*.s3.aws.m.upbound.io
*.ecr.aws.m.upbound.io
*.sqs.aws.m.upbound.io
*.cloudwatchevents.aws.m.upbound.io
```

This is a security boundary as well as a resource-consumption decision. A consuming project cannot provision an RDS instance, an EC2 instance, or an IAM role through Crossplane, because those CRDs are not served - the manifest fails with `no matches for kind` before IAM is ever consulted.

Only the **namespaced** variants are activated, so every Crossplane resource lives in a namespace. Granting a team the ability to provision a bucket is therefore an ordinary namespaced RoleBinding, not a cluster-scoped grant.

---

### Self-hosted CI runners

| Control | State |
|---------|-------|
| GitHub authentication | GitHub App, not a PAT - scoped to its installation, tokens short-lived and refreshed by the listener, not tied to a personal account |
| Credential storage | AWS Secrets Manager, synced by External Secrets into `arc-runners`. No credential material in any Git repository |
| Controller privileges | Non-root, read-only root filesystem, all capabilities dropped, `allowPrivilegeEscalation: false` |
| Namespace split | Controller in `arc-systems`, runners in `arc-runners` - a project can be granted RBAC on its runners without any access to the controller |
| Runner lifecycle | Ephemeral. A pod serves one job and is destroyed, so nothing persists between workflow runs |
| Docker socket | **Not mounted.** `containerMode: dind` is also not used |
| Image builds | Rootless BuildKit sidecar over `tcp://localhost:1234`. No privileged container, no node access |
| Build cache | `emptyDir` - dies with the runner, so no state crosses between jobs from different pull requests |
| Node placement | Karpenter workload nodes, not the core nodes running ArgoCD and Prometheus |
| AWS access | `arc-runner` ServiceAccount via IRSA - ECR push/pull only |
| Deployment gate | The scale set is only created when `github_config_url` is set, so an unconfigured cluster runs no listener |

The Docker socket is a root-equivalent interface to the node: a workflow reaching it can start a privileged container, mount the host filesystem, and read every other pod's secrets. On a runner executing pull-request code that is a cluster takeover. [gitops/ci/README.md](../gitops/ci/README.md) documents a rootless BuildKit sidecar over TCP as the image-build path.

A self-hosted runner executes workflow code, including pull-request code if the repository is configured that way. Every permission on `arc-runner` is therefore reachable by anyone who can open a PR. ECR push means publishing a new tag - the `IMMUTABLE` convention in `examples/crossplane/` prevents overwriting an existing one, but nothing enforces it. For public or fork-accepting repositories, restrict which workflows may run on self-hosted runners.

BuildKit rootless requires `Unconfined` seccomp and AppArmor profiles because it uses user namespaces and overlayfs inside the container. That is a far narrower concession than `privileged`, which is what `dind` would need.

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

| Control | Loki | Thanos | Velero | Tempo |
|---------|------|--------|--------|-------|
| Encryption | SSE-S3 (AES-256) | SSE-S3 (AES-256) | SSE-S3 (AES-256) | SSE-S3 (AES-256) |
| Versioning | Enabled | Enabled | Enabled | Enabled |
| Public access block | All four flags enabled | All four flags enabled | All four flags enabled | All four flags enabled |
| Access logging | Disabled | Disabled | Disabled | Disabled |
| Static credentials | None - IRSA only | None - IRSA only | None - IRSA only | None - IRSA only |

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

### Crossplane and CI

| Item | Current state | What to do |
|------|--------------|------------|
| Crossplane resource settings | Conventions documented in `examples/crossplane/`, not enforced | Add Kyverno `validate` policies in `Enforce` mode for encryption, immutable ECR tags, and public-access blocks. Use `validate`, not `mutate` - a mutation conflicts with ArgoCD `selfHeal` and the Application never reaches Synced |
| Crossplane IAM scope | Account-wide per service, with Terraform-owned resources explicitly denied | Narrow the allow to an enforced ownership tag (`aws:ResourceTag` for ECR/SQS, `s3:BucketTag` for S3) once an admission policy guarantees the tag is present |
| Untagged pre-existing resources | Reachable by the provider roles | Tag all account resources with an ownership key, or adopt a naming convention and add prefix conditions |
| Runner pod security | Non-root, no Docker socket, rootless BuildKit | Add Pod Security Admission or a Kyverno rule on `arc-runners` rejecting `hostPath` mounts of `/var/run/docker.sock`, so a future scale set cannot reintroduce it |
| Runner network egress | Unrestricted | NetworkPolicy on `arc-runners` limiting egress to GitHub, ECR, and DNS |
| Runner ECR scope | Any repository in the region | Add an `aws:ResourceTag` condition once the set of repositories runners publish to is known |
| MLOps role granularity | Two roles: pipeline (read/write) and serving (read, plus PutObject on `observations/`) | A third role for the ingestion worker's SQS access, a fourth for the payload logger so the predictor can go back to read-only, and exact service account names if these namespaces ever host more than one team |
| The `Workload` tag | Nothing enforces it | An admission policy guaranteeing the tag, so a bucket created without it fails at admission rather than with a confusing `AccessDenied` |
| Org-level IAM guardrails | **None** - single account, no SCP, no permissions boundary | A permissions boundary plus an SCP enforcing it (including `iam:PassRole` scoping) is what would make Crossplane-managed IAM safe. See [design decision #29](design-decisions.md#29-iam-guardrails-assumed-at-the-account-layer-not-the-org-layer) |

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
