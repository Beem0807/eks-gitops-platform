# Optional: MLOps platform

An opt-in ArgoCD Application that points this cluster at the separate
[mlops-platform](https://github.com/Beem0807/mlops-platform) repository.

Nothing in this directory is deployed by default.

---

## Why this lives outside `gitops/`

The root Application syncs `path: gitops` with `directory.recurse: true`, which
means **every** manifest under `gitops/` is applied to the cluster. There is no
flag, profile, or values file involved - inclusion is a property of where a file
sits in the tree.

So "optional" cannot be expressed inside `gitops/`. An `enabled: false` value
would not help, because the file would still be discovered and applied. The only
reliable way to keep MLOps out of an EKS-only deployment is to keep it out of
the directory the root app recurses, which is what this top-level `optional/`
directory is for.

The alternative was adding `directory.exclude` to the root app. That was
rejected: it makes the default deployment depend on a glob matching correctly,
and the failure mode is silent - a typo in the pattern deploys MLOps to every
EKS-only cluster, which is exactly the outcome this is meant to prevent.

---

## What an EKS-only deployment gets

Nothing from here. No `mlops` AppProject, no namespaces, no MLOps workloads.

[SimpleTimeService](../../charts/simple-time-service/) is unaffected either way.
It is deployed by `gitops/app/simple-time-service/` as part of the platform's own
demonstration, is not referenced by the MLOps Application, and is not deployed,
modified, or removed when MLOps is enabled. The two are independent.

---

## Enabling it

Both files are needed, and order matters - the AppProject must exist before the
Application that references it, or the Application reports
`Application referencing project mlops which does not exist`.

```bash
kubectl apply -f optional/mlops/
```

`kubectl apply -f <directory>` applies files alphabetically, so
`mlops-platform.yaml` would be applied before `mlops-project.yaml`. ArgoCD
retries, so this resolves itself within a reconcile - but to avoid the
transient error:

```bash
kubectl apply -f optional/mlops/mlops-project.yaml
kubectl apply -f optional/mlops/mlops-platform.yaml
```

Then watch it come up:

```bash
kubectl get application mlops-platform -n argocd -w
kubectl get applications -n argocd -l app.kubernetes.io/component=mlops
```

---

## Disabling it

```bash
kubectl delete -f optional/mlops/
```

The Application syncs with `prune: true`, so deleting it removes the MLOps
workloads it created. Deleting the Application does **not** delete AWS resources
that the MLOps platform provisioned through Crossplane unless the Crossplane
managed resources are themselves pruned first - check for leftovers before
assuming the account is clean:

```bash
kubectl get managed
```

---

## Prerequisites

Ordered end-to-end walkthrough, including the two GitHub Apps:
[docs/first-deployment.md](../../docs/first-deployment.md).

| Requirement | Why |
|-------------|-----|
| Platform deployed and healthy through wave 14 | The MLOps platform builds on Crossplane and the observability stack |
| The `mlops-platform` repository reachable by ArgoCD | It is public; a private repo needs a repository credential in ArgoCD |
| `platform-runners` scale set running | **Required**, not optional. Both MLOps workflows need it: one for the rootless BuildKit sidecar, the other because the Kubeflow Pipelines API is a ClusterIP service a GitHub-hosted runner cannot reach. Platform-owned - see [gitops/ci/README.md](../../gitops/ci/README.md) |
| KEDA installed | The ingestion worker is a `ScaledJob`, so without KEDA no dataset upload is ever processed. Installed by `gitops/auto-scaling/keda/` on every cluster |
| `mlops_github_app_*` Terraform variables set | The ingestion worker commits a dataset pointer back to the MLOps repository. Without them the Secrets Manager entry exists but is empty, and the worker fails its push after validating a batch |
| GitHub OIDC role, as a repository variable | The MLOps workflows assume a role for ECR. The provider and the role already exist in the account, so nothing here creates them - the MLOps repository needs `AWS_ROLE_ARN` set as a repository variable. `AWS_REGION` is optional there; its workflows default to `ap-south-1`, matching `terraform.tfvars` |

### What the platform hands over

Three things the MLOps repository consumes but does not create:

| | Created by | Consumed as |
|---|---|---|
| `mlops-pipeline` / `mlops-serving` IAM roles | `terraform/mlops-workload-irsa.tf` | Annotations on the ArgoCD cluster Secret, read by the MLOps ApplicationSets |
| `mlops-ingestion-github-app` Secrets Manager entry | `terraform/mlops-secrets.tf` | An `ExternalSecret` in `mlops-system` |
| `charts/raw` and `charts/namespaces` | This repository | Helm chart paths referenced at `targetRevision: main` |

That last one is a real coupling: moving or renaming either chart breaks the
MLOps repository. Both should be treated as a published interface.

Note the serving role is **read-only on S3 except `s3:PutObject` under
`observations/`**. KServe's inference logger writes payload logs from inside
the predictor pod, so drift detection has no input without that grant. See
design decision 32.

---

## These two files are not self-healing

Everything under `gitops/` is reconciled by the root app, so a manual change to
it is reverted. These two files are applied by hand and are therefore **not**
managed by ArgoCD: editing `mlops-project.yaml` in Git does not change the
cluster until it is re-applied.

That is a deliberate consequence of being opt-in - a self-healing opt-in
toggle would have to be declared somewhere the root app reads, which is the
thing being avoided. Re-apply after changing either file:

```bash
kubectl apply -f optional/mlops/
```

---

## Adding a chart repository

`mlops-project.yaml` lists allowed source repositories explicitly. When the
MLOps platform adds a component from a new chart repository, its Application
fails with:

```
application repo https://example.github.io/charts is not permitted in project 'mlops'
```

Add the repository to `spec.sourceRepos` in `mlops-project.yaml` and re-apply.
