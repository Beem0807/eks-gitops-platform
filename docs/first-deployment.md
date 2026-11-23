# First deployment, end to end

The ordered path from nothing to a running platform. Everything here is also
covered in the component READMEs — this exists because the *order* matters and
those are organised by component, not by sequence.

Read [the README's Prerequisites](../README.md#prerequisites) first for the
tool list and the **ACM certificate**, which must be `ISSUED` before
`bootstrap.sh` runs.

## What is actually required

Only steps 1–2. Everything after them is optional and additive.

| | Needs a GitHub App? | Needs `github_config_url`? |
|---|---|---|
| **EKS platform alone** (steps 1–2) | **no** | **no** |
| \+ self-hosted runners (step 3) | App 1 | yes |
| \+ the MLOps platform (step 4) | App 1 **and** App 2 | yes |

An EKS-only deployment needs **no GitHub App at all**. With
`github_config_url` empty, no runner scale set is created — the ARC controller
still installs but has nothing to run, which costs one idle Deployment and
nothing else. Both Secrets Manager entries are created either way with empty
values, because External Secrets fails on an *absent* property but accepts an
empty one.

The MLOps platform lives in a separate repository and is opt-in **by
location**: the root Application syncs `path: gitops` recursively, and the
MLOps integration sits in a top-level `optional/` directory the root app never
reads. An EKS-only cluster gets no MLOps namespaces, no `mlops` AppProject and
no MLOps workloads — not because a flag is off, but because nothing points at
them.

The MLOps repository's workflows are the only ones in either repository that
use `runs-on: platform-runners`. This repository's own CI runs on
`ubuntu-latest`. So the runner scale set exists *for* the MLOps repository —
which is why step 3 is grouped with it rather than with the platform.

---

## 1. Bootstrap the platform

This is the whole EKS-only deployment. One required variable:

```bash
cd eks-gitops-platform

export TF_VAR_alertmanager_slack_webhook_url="<slack incoming webhook>"

bash terraform/scripts/bootstrap.sh
```

That is it. No GitHub App, no `github_config_url`. All seven GitHub variables
default to empty, so the apply is unaffected: the Secrets Manager entries are
created with empty values, the ARC controller installs, and no runner scale set
is generated because the ApplicationSet selects on a `github-runners=enabled`
label that `bootstrap.sh` only sets when `github_config_url` is non-empty.

`bootstrap.sh` also prompts for, or generates, the ArgoCD and Grafana admin
credentials — see [terraform/README.md](../terraform/README.md#bootstrapsh---full-cluster-bring-up).

If you already know you want runners and the MLOps platform, add the exports
from [step 3](#3-optional--github-apps-runners-and-mlops) to this same command
rather than re-running `bootstrap.sh` later. Adding them afterwards is
supported — `upgrade.sh` re-applies the cluster Secret and the scale set
appears — so there is no need to decide now.

## 2. Verify the platform

```bash
kubectl get applications -n argocd            # all Synced / Healthy
kubectl get pods -n crossplane-system         # core + rbac-manager Running
kubectl get pods -n keda                      # keda-operator Running
kubectl get pods -n arc-systems               # ARC controller Running
```

**`arc-runners` is expected to be empty at this point.** The ARC *controller*
installs unconditionally, but no runner scale set is generated without
`github_config_url`, so there is no listener pod. That is the correct state for
an EKS-only cluster, not a failure:

```bash
kubectl get pods -n arc-runners               # No resources found  <- expected
```

Likewise `keda-operator` runs with nothing to scale — a `ScaledJob` only exists
once the MLOps platform is enabled.

### What happens to the CI ApplicationSets

Three ApplicationSets live under `gitops/ci/`, and they behave differently
because only one of them is gated:

| ApplicationSet | Wave | EKS-only outcome |
|----------------|------|------------------|
| `actions-runner-controller` | 11 | **Installs.** Ungated, so the controller Deployment runs — idle, watching for scale sets that do not exist. One pod. |
| `arc-runner-identity` | 5 | **Syncs, Healthy.** Ungated: the `arc-github-app` ExternalSecret pulls the Secrets Manager entry, which Terraform wrote with three **empty** values, plus the `arc-runner` ServiceAccount. |
| `arc-runner-scale-set` | 12 | **Generates nothing.** Its cluster generator selects `github-runners: enabled`; `bootstrap.sh` sets the label to `disabled`, so the selector matches no cluster and **zero Applications** are produced. |

Two things are worth knowing about that table.

**An ApplicationSet that generates zero Applications is Healthy, not failed.**
There is no error state to chase — `kubectl get applicationset -n argocd`
shows the object, and `kubectl get applications -n argocd | grep arc-runner-scale-set`
returns nothing. That is the designed outcome.

**The empty Secret is deliberate, and brittle in a specific way.** External
Secrets fails an ExternalSecret when a referenced *property* is absent but
accepts an empty *value*, so `terraform/actions-runner-controller.tf` always
writes all three keys even when they are blank. Making them conditional would
break `arc-runner-identity` with `key githubAppId does not exist in secret
arc-github-app` — on a cluster that is not even using runners. The same
applies to `mlops-ingestion-github-app`.

The cost of the two that do install is one idle controller pod and an empty
Secret. The alternative — gating all three — was rejected because the
controller is a platform capability a consuming project may enable later via
`upgrade.sh`, with no cluster rebuild.

Full troubleshooting table: [gitops/ci/README.md](../gitops/ci/README.md).

The platform's own
[validation checklist](../README.md#validation-checklist) covers the rest.

At this point the platform is complete and usable: ArgoCD, the observability
stack, Karpenter, Crossplane, cert-manager, ExternalDNS, the ALB controller and
SimpleTimeService as its demonstration workload. **Stop here unless you want
self-hosted runners or the MLOps platform.**

---

## 3. Optional — GitHub Apps, runners and MLOps

Skip this entire section for an EKS-only cluster. Nothing above depends on it.

**A personal account is enough. No organisation, no cost.**

Two Apps, not one, and the separation is the point: the second can push to a
default branch, and no CI runner should hold commit rights it has no use for.
App 1 is needed as soon as you want self-hosted runners; App 2 only for MLOps
dataset ingestion.

Both start at: github.com → your avatar → **Settings** → **Developer settings**
→ **GitHub Apps** → **New GitHub App**.

### Settings common to both

| Field | Value |
|-------|-------|
| GitHub App name | must be globally unique, e.g. `<you>-arc-runners` |
| Homepage URL | anything; your repository URL is fine |
| **Webhook → Active** | **uncheck it** — ARC polls the API and the ingestion worker never receives callbacks, so an active webhook with no listener just generates delivery failures |
| Where can this App be installed? | **Only on this account** |

### App 1 — runners

Repository permissions, everything else left at *No access*:

| Permission | Access |
|------------|--------|
| Administration | **Read and write** |
| Metadata | Read-only (selected automatically) |

There is deliberately no *Organisation → Self-hosted runners* option on a
personal account; that permission group only exists for organisations. Repository
scope is therefore the only choice, and the scale set serves **one** repository.
See [gitops/ci/README.md](../gitops/ci/README.md#creating-the-app).

### App 2 — MLOps ingestion

| Permission | Access |
|------------|--------|
| Contents | **Read and write** |
| Metadata | Read-only |

### For each App, after creating it

1. The **App ID** is at the top of its settings page.
2. **Private keys** → **Generate a private key**. A `.pem` downloads.
   **GitHub never shows it again** — losing it means generating a new one.
3. Sidebar → **Install App** → Install → **Only select repositories** →
   `mlops-platform`.
4. The resulting URL ends `.../settings/installations/<NUMBER>`. That number is
   the **Installation ID** — it is *not* the App ID.

### Supplying them

Either add these to the `bootstrap.sh` invocation in step 1, or export them now
and run `upgrade.sh` against the running cluster:

```bash
# App 1 - runners. Required for `runs-on: platform-runners` to resolve.
export TF_VAR_github_app_id="<app 1 App ID>"
export TF_VAR_github_app_installation_id="<app 1 Installation ID>"
export TF_VAR_github_app_private_key="$(cat ~/Downloads/<app-1>.private-key.pem)"

# Which GitHub scope the scale set registers with.
#
# Point this at the MLOPS repository, not this one. The only workflows using
# `runs-on: platform-runners` are there; this repository's own CI runs on
# ubuntu-latest. Leaving it empty is what disables the scale set entirely.
export TF_VAR_github_config_url="https://github.com/Beem0807/mlops-platform"

# App 2 - MLOps dataset ingestion. Only needed for the MLOps platform; the
# runners work without it.
export TF_VAR_mlops_github_app_id="<app 2 App ID>"
export TF_VAR_mlops_github_app_installation_id="<app 2 Installation ID>"
export TF_VAR_mlops_github_app_private_key="$(cat ~/Downloads/<app-2>.private-key.pem)"

export TF_VAR_alertmanager_slack_webhook_url="<slack incoming webhook>"

bash terraform/scripts/upgrade.sh      # or bootstrap.sh, on a first run
```

`bootstrap.sh` and `upgrade.sh` both **refuse to start** if
`github_config_url` is set while any App 1 value is missing — that combination
deploys a scale set whose listener crash-loops against the GitHub API with an
error naming nothing useful. Both print which Apps are configured at the end
of a run.

Then confirm the runners registered:

```bash
kubectl get pods -n arc-runners        # listener Running, not CrashLoopBackOff
kubectl get autoscalingrunnerset -n arc-runners
```

---

## 4. Enable the MLOps platform

Opt-in by location — the root app never reads `optional/`, so these are applied
by hand and are **not** self-healing:

```bash
kubectl apply -f optional/mlops/mlops-project.yaml
kubectl apply -f optional/mlops/mlops-platform.yaml
kubectl get application mlops-platform -n argocd -w
```

See [optional/mlops/README.md](../optional/mlops/README.md).

---

## 5. Set up the MLOps repository

```bash
cd ../mlops-platform

# The OIDC role already exists in the account (created alongside the portfolio
# website), so this is just pointing CI at it.
gh variable set AWS_ROLE_ARN --body 'arn:aws:iam::<account>:role/<ci-role>'
# AWS_REGION is optional - both workflows default to ap-south-1.
```

### Seed the dataset

The raw dataset is not in Git. The committed `.dvc` pointer records where it
came from and what it must hash to; the bytes have to reach the DVC remote once
per version:

Two steps, and two different buckets:

```bash
# 1. the raw CSV goes to the SOURCE bucket, at an exact key.
#    nabeem-releases is the bucket; release.nabeem.com is the CloudFront
#    domain in front of it. They are not the same name.
aws s3 cp creditcard.csv s3://nabeem-releases/datasets/creditcard/v1/creditcard.csv
curl -sI https://release.nabeem.com/datasets/creditcard/v1/creditcard.csv | head -3

# 2. seed the DVC remote from it
./scripts/seed-dataset.sh
```

Until step 2 runs, pipeline steps fail at `preprocessing.fetch` with a message
naming the missing object. Note that a plain `aws s3 cp` into the **DVC
remote** does **not** work — that one is content-addressed, so the key is
derived from the file's hash rather than its name. See
[data/raw/README.md](https://github.com/Beem0807/mlops-platform/blob/main/applications/fraud-detection/data/raw/README.md).

### Build the images

Nothing serves until the three images exist and the manifests are pinned to
their digests:

```bash
gh workflow run build-images.yml
```

`train.yml` checks that the pipeline image is digest-pinned and fails with a
message saying to run the build first, rather than submitting a pipeline that
cannot pull.

---

## 6. Exercise the loop

```bash
# Upload a batch: EventBridge -> SQS -> KEDA -> Job -> commit -> CI -> pipeline
./scripts/drift-fixture.py --mode amount --out /tmp/batch-002.csv
aws s3 cp /tmp/batch-002.csv s3://fraud-detection-datasets/raw/batch-002.csv

# Watch each hop
kubectl get jobs -n mlops-system -w                    # KEDA created a Job
kubectl logs -n mlops-system -l app.kubernetes.io/name=fraud-detection-ingestion
git -C . pull && git log --oneline -3                  # the worker's commit
gh run list --workflow=train.yml                       # CI submitted a run
```

Then promote a model — two lines in two files, reviewed. That step is
deliberately manual; see
[model-promotion.md](https://github.com/Beem0807/mlops-platform/blob/main/docs/model-promotion.md).

---

## What this does not cover

None of the above has been executed. The manifests are schema-validated, the
Python is tested, the workflows parse — but no cluster has been created from
this repository since these changes, and neither MLOps workflow has ever run.
Expect to debug sync-wave ordering, CRD readiness and IRSA token exchange on
the first real attempt.
