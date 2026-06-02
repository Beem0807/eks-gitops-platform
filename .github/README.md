# CI Workflows

Two workflows gate changes to this repository. Both are triggered by pull requests and pushes to `main`, scoped to their relevant paths.

---

## `app-image.yaml` - Docker Image CI

**Triggers:** changes under `app/**` or the workflow file itself.

| Event | Steps |
|-------|-------|
| Pull request | Build (amd64) → Trivy scan → post results as PR comment |
| Push to `main` | Build (amd64) → Trivy scan → push multi-platform image (amd64 + arm64) to Docker Hub |

**Trivy scan** checks for `CRITICAL` and `HIGH` vulnerabilities in the container image. Unfixed CVEs are ignored. Results are posted as a PR comment and uploaded to the GitHub Security tab (SARIF). The job fails and blocks merge if vulnerabilities are found.

**Image tags pushed on merge to `main`:**
- Short commit SHA (e.g. `a1b2c3d`) - immutable per-commit reference
- `latest` - always tracks `main`

**Required secrets:**

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

---

## `terraform-ci.yaml` - Terraform CI

**Triggers:** pull requests to `main` with changes under `terraform/**` or the workflow file itself. Does not run on push to `main` - if branch protection requires this check to pass, nothing broken can reach `main`.

### Job: `validate`

Runs on every PR to `main`.

| Step | What it checks |
|------|----------------|
| `terraform fmt -check -recursive` | All `.tf` files are correctly formatted |
| `terraform init -backend=false` + `terraform validate` | Valid HCL, all references resolve - runs for both root module and `app-bootstrap` |
| TFLint | AWS-specific lint rules using `tflint-ruleset-aws` |

TFLint results are posted as a PR comment when issues are found.

### Job: `security`

Runs on every PR to `main`.

| Step | What it checks |
|------|----------------|
| Checkov | Security misconfigurations in Terraform (IAM, S3, encryption, networking) |

Checkov results are posted as a PR comment on failure and uploaded to the GitHub Security tab (SARIF).

**Skipped checks** (documented in `terraform/.checkov.yaml`):

| Check | Scope | Reason |
|-------|-------|--------|
| `CKV_TF_1` | Global | Applies to `git://` sources only; Terraform Registry modules use version pinning |
| `CKV_AWS_149` | Secrets Manager | Default encryption (SSE) is sufficient; KMS CMK not required for this environment |
| `CKV2_AWS_57` | Secrets Manager | Automatic rotation requires a Lambda rotator; secrets are manually managed |
| `CKV_AWS_18` | S3 (loki, thanos, velero) | Access logging not required for internal observability and backup buckets |
| `CKV_AWS_144` | S3 (loki, thanos, velero) | Cross-region replication not required for a single-region deployment |
| `CKV_AWS_145` | S3 (loki, thanos, velero) | SSE-S3 default encryption is sufficient; KMS CMK not required |
| `CKV2_AWS_61` | S3 (loki, thanos, velero) | Lifecycle policies are managed by the applications (Loki, Thanos, Velero), not at the bucket level |
| `CKV2_AWS_62` | S3 (loki, thanos, velero) | Event notifications not required for observability and backup buckets |

**Inline skips** (inside the affected resource blocks) are used for IAM policies where AWS does not support resource-level ARNs:

| Check | Resource | Reason |
|-------|----------|--------|
| `CKV_AWS_356` | `cluster_autoscaler` | `autoscaling:Describe*` and `ec2:Describe*` do not support resource-level ARNs in AWS |
| `CKV_AWS_356` | `external_dns` | `route53:List*` actions do not support resource-level ARNs in AWS |
| `CKV_AWS_111`, `CKV_AWS_356` | `velero` | `ec2:CreateSnapshot` and `ec2:Describe*` do not support resource-level ARNs in AWS |

---

## Branch protection

To enforce that all checks must pass before a PR can be merged, configure branch protection on `main`:

**Settings → Branches → Add rule → Require status checks to pass → add `build-and-scan`, `validate`, `security`**
