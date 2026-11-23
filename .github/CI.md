# CI Workflows

Six workflows gate changes to this repository. All are triggered by pull requests to `main`, scoped to their relevant paths.

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
| `CKV_AWS_111`, `CKV_AWS_356` | `crossplane_s3` | Consuming projects name their own buckets, so there is no prefix or tag to condition the allow on. S3 bucket ARNs are also global, so `arn:aws:s3:::*` is the only expressible scope. Terraform-owned buckets are carved out by an explicit `Deny` |
| `CKV_AWS_111`, `CKV_AWS_356` | `crossplane_ecr` | Scoped to `repository/*` in one account and region; narrowing further would impose a naming convention on every consuming repository. Terraform-owned repositories are carved out by an explicit `Deny` |
| `CKV_AWS_111`, `CKV_AWS_356` | `crossplane_sqs` | Scoped to one account and region; the Karpenter interruption queue is carved out by an explicit `Deny` |
| `CKV_AWS_111`, `CKV_AWS_356` | `mlops_pipeline` | Resources are provisioned by Crossplane after the role exists, so the policy authorises by `Workload` tag rather than by ARN. S3 bucket ARNs are also global |
| `CKV_AWS_356` | `mlops_serving` | Same tag-based scoping; this policy grants no write action at all |
| `CKV_AWS_111`, `CKV_AWS_356` | `crossplane_events` | Scoped to EventBridge rules in one account and region; `events:ListRules` is bus-scoped and cannot be narrowed to a rule ARN |

See [design decision #24](../docs/design-decisions.md#24-eks-pod-identity-for-crossplane-and-deny-based-iam-scoping) for why the Crossplane policies are scoped with a deny rather than a conditional allow.

---

## `gitops-ci.yaml` - GitOps / Kubernetes CI

**Triggers:** pull requests to `main` with changes under `gitops/**`, `k8s/**`, `charts/**`, `optional/**`, or `examples/**`.

Protects the GitOps repo from broken YAML, invalid manifests, and broken Helm templates before ArgoCD ever sees them.

### Job: `helm`

| Step | What it checks |
|------|----------------|
| `helm lint` | Chart structure and values for all three charts (`simple-time-service`, `namespaces`, `raw`) |
| `helm template \| kubeconform` | Rendered manifests from `simple-time-service` and `namespaces` are valid Kubernetes resources against the 1.34 schema |

`charts/raw` is only linted, not templated - it is a passthrough chart that requires caller-supplied `Values.resources` to produce output.

### Job: `manifests`

| Step | What it checks |
|------|----------------|
| `kubeconform` on `k8s/` | Strict schema validation against Kubernetes 1.34 |
| `kubeconform` on `gitops/` and `optional/` | Schema validation with `--ignore-missing-schemas` - standard K8s resources are validated; ArgoCD and Prometheus CRDs are skipped |
| ApplicationSet Go template options | Every `kind: ApplicationSet` file must have `goTemplate: true` and `goTemplateOptions: ["missingkey=error"]` |
| Optional manifests stay optional | Fails if any manifest under `gitops/` references the `mlops-platform` repo, and if `optional/mlops/mlops-platform.yaml` is missing |

**Why the ApplicationSet check matters:**
- `goTemplate: true` - enables Go template syntax in the ApplicationSet generator; without it, template expressions are rendered literally
- `missingkey=error` - makes ArgoCD fail at sync time if a template variable is undefined, instead of silently rendering an empty string which can produce broken manifests that pass validation but misbehave at runtime

**Why the optional-manifest check matters:**

The root Application syncs `path: gitops` with `directory.recurse: true`, so inclusion in a deployment is a property of *where a file sits*, not of its contents. A manifest referencing the MLOps repo placed anywhere under `gitops/` would be applied to every cluster, including EKS-only ones. The check asserts the boundary rather than trusting the directory layout to stay correct through future edits.

### Job: `yaml-lint`

Runs `yamllint` across `gitops/`, `k8s/`, `charts/`, `optional/`, and `examples/` (excluding `charts/*/templates/` which contain Go template syntax).

Config is in `.yamllint.yaml` at the repo root. It extends `yamllint`'s built-in `default` profile and overrides the following rules:

| Rule | Setting | Reason |
|------|---------|--------|
| `document-start` | disabled | Leading `---` is optional in Kubernetes YAML; all files omit it |
| `line-length` | max 150 chars, **warning** only | Prometheus query expressions and Grafana dashboard JSON embed long strings that cannot be split |
| `truthy` | `true` / `false` only, keys not checked | Matches Kubernetes boolean conventions; prevents false positives on ArgoCD `syncPolicy` fields |
| `comments` | 1 space from content | Allows `# comment` style used in values files; the default requires 2 spaces |

**Ignored paths** (Go template syntax is not valid YAML):

```
charts/*/templates/
charts/*/templates/**
```

All three jobs post results as a PR comment on failure.

---

## `actions-check.yaml` - GitHub Actions Check

**Triggers:** pull requests to `main` with changes under `.github/workflows/**`.

### Job: `Lint Workflows`

Runs [`actionlint`](https://github.com/rhysd/actionlint) across all workflow files in `.github/workflows/`. Catches issues before they reach GitHub Actions runners:

- Invalid expression syntax (`${{ }}`)
- References to undefined contexts or outputs
- Type mismatches (e.g. passing a string where a boolean is expected)
- Invalid `if:` conditionals
- Incorrect `needs:` job references
- Missing required inputs on `workflow_call`

Results are posted as a PR comment on failure.

---

## `codeowners-check.yaml` - CODEOWNERS Check

**Triggers:** pull requests to `main` with changes to `.github/CODEOWNERS`.

### Job: `validate`

Runs [`codeowners-validator`](https://github.com/mszostok/codeowners-validator) against `.github/CODEOWNERS` with three checks:

| Check | What it validates |
|-------|-------------------|
| `syntax` | File follows the valid CODEOWNERS pattern format |
| `duppatterns` | No two entries match the same glob pattern |

The `owners` check is excluded - it requires `read:org` OAuth scope which the default `GITHUB_TOKEN` does not have.

Results are posted as a PR comment on failure.

---

## `pr-title-check.yaml` - PR Title Check

**Triggers:** all pull requests to `main` (no path filter) on `opened`, `edited`, `synchronize`, and `reopened` events.

### Job: `validate`

Validates that the PR title follows [Conventional Commits](https://www.conventionalcommits.org/) format using [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request).

**Format:** `<type>[optional scope]: <description>`

**Valid types:**

| Type | Use for |
|------|---------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `chore` | Maintenance, dependency updates |
| `docs` | Documentation only |
| `ci` | CI/CD pipeline changes |
| `refactor` | Code restructuring without behaviour change |
| `test` | Adding or updating tests |
| `perf` | Performance improvements |
| `style` | Formatting, whitespace (no logic change) |
| `revert` | Reverting a previous commit |

**Examples:**
- `feat: add velero backup schedule`
- `fix(app): correct health check endpoint`
- `ci: add pr title check workflow`

The `synchronize` trigger ensures branch protection always sees a current status on the latest commit, even when only the branch is updated without editing the title. On failure, a PR comment is posted with the current title, the expected format, and examples. The comment is updated in place if the title is edited and still fails.

---

## Branch protection

To enforce that all checks must pass before a PR can be merged, configure branch protection on `main`:

**Settings → Branches → Add rule → Require status checks to pass → add `Build and Trivy Scan`, `Validate Terraform`, `Checkov Scan`, `Helm Lint`, `Validate Manifests`, `YAML Lint`, `Lint Workflows`, `Validate CODEOWNERS`, `Validate PR Title`**

> `validate` appears in both `terraform-ci` and `codeowners-check`. GitHub treats status checks by job name - both must pass when both are triggered.
