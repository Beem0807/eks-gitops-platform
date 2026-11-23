# CI - GitHub Actions Runner Controller

Self-hosted GitHub Actions runners that run as ephemeral pods in this cluster.

Both halves are **platform-owned**: the controller and a general-purpose runner
scale set. Any repository in the organisation targets it with
`runs-on: platform-runners`.

| Wave | ApplicationSet | Namespace | What it does |
|------|----------------|-----------|--------------|
| 5 | `arc-runner-identity` | `arc-runners` | GitHub App Secret from Secrets Manager, plus the runner ServiceAccount carrying the ECR IRSA role |
| 11 | `actions-runner-controller` | `arc-systems` | The controller and its four CRDs |
| 12 | `arc-runner-scale-set` | `arc-runners` | The `platform-runners` scale set - **only when configured**, see below |

ARC splits into a controller that watches `AutoScalingRunnerSet` resources, and
a per-scale-set *listener* that long-polls GitHub for jobs and scales runner
pods. The controller never talks to GitHub; the listener does.

---

## Which ARC this is

`gha-runner-scale-set-controller`, the current autoscaling-runner-scale-set
architecture — **not** the older `RunnerDeployment` controller. Both are called
"actions-runner-controller", they are different products with incompatible
CRDs, and only this one supports the ephemeral, GitHub-managed scale sets used
here.

The controller watches all namespaces (`flags.watchSingleNamespace` is
deliberately unset).

`ServerSideApply=true` is **required**, not stylistic: the
`AutoScalingRunnerSet` CRD alone is about 1.2 MB, and client-side apply stores
the whole manifest in the `last-applied-configuration` annotation, capped at
256 KB.

---

## The scale set is gated on configuration

`arc-runner-scale-set` is the only ApplicationSet in this repository whose
cluster generator selects on a second label:

```yaml
selector:
  matchLabels:
    argocd.argoproj.io/secret-type: cluster
    github-runners: enabled
```

`bootstrap.sh` and `upgrade.sh` set that label to `enabled` only when
`github_config_url` is non-empty. With the label absent, the generator produces
no Application at all — nothing is created, nothing shows Degraded, nothing to
prune later.

This gate is necessary rather than neat. An unconfigured *controller* is
harmless — it connects to nothing. An unconfigured *scale set* is not: its
listener pod crash-loops against the GitHub API indefinitely. An EKS-only
cluster must not receive one.

---

## Two couplings that will bite if you rename things

**1. `controllerServiceAccount` must be pinned.** The scale set chart creates a
RoleBinding granting the controller access to `arc-runners`, and by default it
discovers the controller's ServiceAccount with a Helm `lookup` against the live
cluster. ArgoCD's repo-server renders charts **without** cluster access, so the
lookup returns nil and the chart fails outright:

```
No gha-rs-controller deployment found using label
(app.kubernetes.io/part-of=gha-rs-controller)
```

Hence the explicit value:

```yaml
controllerServiceAccount:
  name: arc-gha-rs-controller      # <controller releaseName>-gha-rs-controller
  namespace: arc-systems
```

Renaming the controller's `releaseName` in
`actions-runner-controller.yaml` breaks the scale set. This is also the main
reason scale sets are kept in this repository: any scale set anywhere has to
hardcode this platform-internal name, which is a poor seam to put across a
repository boundary.

**2. The Helm release name is the runner label.** `releaseName:
platform-runners` becomes the scale set name, which is what workflows put in
`runs-on`. Renaming it breaks every workflow targeting it.

---

## Using the runners

```yaml
jobs:
  build:
    runs-on: platform-runners
```

`minRunners: 0`, so nothing idles when there are no jobs. The first job after a
quiet period waits for a pod, and for a Karpenter node if the cluster has to
grow — a cold start of a minute or two is the trade for not paying for idle
capacity. `maxRunners: 5` caps concurrency.

Runner pods land on Karpenter **workload** nodes
(`nodeSelector: app=workload`), not the core nodes running ArgoCD and
Prometheus. A build that exhausts memory should take out a disposable workload
node, not the control plane.

### AWS access

Runner pods use the `arc-runner` ServiceAccount, which carries an IRSA
annotation for `<cluster>-arc-runner` (see
[terraform/arc-runner-irsa.tf](../../terraform/arc-runner-irsa.tf)). It grants
ECR push and pull, and nothing else.

Three distinct identities are involved in getting an image into a pod, and it is
worth keeping them straight:

| Identity | Does |
|----------|------|
| `arc-runner` ServiceAccount | **Pushes** images to ECR |
| Karpenter node IAM role | **Pulls** images for pods. Already granted by the Karpenter module |
| `provider-aws-ecr` (Crossplane) | **Creates** the repositories. Cannot push images |

None can do another's job.

> A self-hosted runner executes workflow code, including pull-request code if
> the repository is configured that way. Every permission on `arc-runner` is
> therefore reachable by anyone who can open a PR. ECR push means publishing a
> new tag; the `IMMUTABLE` convention in `examples/crossplane/` stops an
> existing tag being overwritten, but nothing enforces it. For public or
> fork-accepting repositories, restrict which workflows may run on self-hosted
> runners.

### Building images — no Docker socket

The runner pod has a rootless **BuildKit** sidecar on `tcp://localhost:1234`,
with `BUILDKIT_HOST` already set in the runner container. Use
`docker/build-push-action` with `driver: remote`, or `buildctl` directly.

Deliberately **not** `containerMode: dind`, and deliberately no `hostPath`
mount of `/var/run/docker.sock`. The Docker socket is a root-equivalent
interface to the node: a workflow reaching it can start a privileged container,
mount the host filesystem, and read every other pod's secrets. On a runner
executing pull-request code that is cluster takeover, not a hardening nit.
`dind` is the same exposure in a different shape — it needs a privileged
container.

BuildKit rootless needs `Unconfined` seccomp and AppArmor profiles because it
uses user namespaces and overlayfs inside the container. That is a far narrower
concession than `privileged`.

The build cache is an `emptyDir`, so it dies with the runner. A persistent
cache would be faster but would carry state between jobs — including jobs from
different pull requests, which is exactly what an ephemeral runner exists to
prevent.

---

## The GitHub App credentials

A GitHub App rather than a PAT: scoped to its installation, tokens short-lived
and refreshed by the listener, not tied to anyone's personal account.

No plaintext in Git — the same path as the Grafana and Alertmanager secrets:

```
TF_VAR_github_app_*
  → AWS Secrets Manager "arc-github-app"     terraform/actions-runner-controller.tf
    → ExternalSecret                          gitops/ci/.../arc-runner-identity.yaml
      → Secret "arc-github-app"               in arc-runners
        → the scale set listener              githubConfigSecret: arc-github-app
```

The Secret lands in `arc-runners` because listeners run in the namespace their
`AutoScalingRunnerSet` lives in.

### Creating the App

For the full first-time sequence - both Apps, the Terraform variables, and
what to verify after bootstrap - see
[docs/first-deployment.md](../../docs/first-deployment.md).

Settings → Developer settings → GitHub Apps → New GitHub App. **A personal
account works and costs nothing** - an organisation is not required.

Permissions depend on the scope the runners serve, which must match
`github_config_url`:

| Scope | `github_config_url` | Permissions | Needs an org? |
|-------|---------------------|-------------|---------------|
| Organisation-wide | `https://github.com/<org>` | Organisation → *Self-hosted runners*: Read & write | **yes** |
| Single repository | `https://github.com/<owner>/<repo>` | Repository → *Administration*: Read & write; *Metadata*: Read-only | no |

Org-wide is the better choice for a shared platform runner when an
organisation exists - it lets any repository use the runners without a new
installation. On a personal account the *Organisation* permission group does
not exist, so repository scope is the only option, and the scale set serves
**one** repository.

That is not a limitation in practice here: the only workflows using
`runs-on: platform-runners` are in the MLOps repository, so point
`github_config_url` at that one. This repository's own workflows run on
`ubuntu-latest` and need no self-hosted runner.

Then **Install** the App on the org or repo, and read the installation ID out of
the resulting URL (`.../installations/<id>`). Generate and download the private
key once at creation; GitHub will not show it again.

### Supplying them

```bash
export TF_VAR_github_app_id="123456"
export TF_VAR_github_app_installation_id="12345678"
export TF_VAR_github_app_private_key="$(cat ~/Downloads/arc-app.private-key.pem)"
# Org-wide: https://github.com/<org>
# Personal account (repo scope): https://github.com/Beem0807/mlops-platform
export TF_VAR_github_config_url="https://github.com/Beem0807/mlops-platform"

bash terraform/scripts/upgrade.sh
```

`upgrade.sh` re-applies the cluster Secret — which flips the `github-runners`
label to `enabled` and makes the scale set appear — and force-annotates every
ExternalSecret so the credential refreshes immediately rather than on the next
hourly interval.

| Secret key | Secrets Manager property | Notes |
|------------|--------------------------|-------|
| `github_app_id` | `githubAppId` | Key names are required verbatim by the scale set chart |
| `github_app_installation_id` | `githubAppInstallationId` | |
| `github_app_private_key` | `githubAppPrivateKey` | Full PEM including header and footer |

All four variables default to `""`, so an EKS-only deployment applies cleanly
and `bootstrap.sh` does not require them. The `arc-github-app` Secrets Manager
entry is created regardless; the ExternalSecret syncs three empty values and
still reports `SecretSynced`, because External Secrets only fails on an *absent*
property, not an empty one.

---

## If a project needs a different runner shape

The platform pool is one shape. A project needing GPU, much larger limits, or a
custom runner image can deploy its own scale set into `arc-runners` from its own
repository, reusing `githubConfigSecret: arc-github-app` and pinning the same
`controllerServiceAccount` block above. Use a distinct `releaseName`, since that
becomes the `runs-on` label.

Do **not** install a second ARC controller — the two would fight over the same
cluster-scoped CRDs.

---

## Verifying

```bash
# Controller
kubectl get deploy -n arc-systems
kubectl logs -n arc-systems deploy/arc-gha-rs-controller

# Is the scale set gated off? Check the label the generator selects on.
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{.items[0].metadata.labels.github-runners}{"\n"}'

# Scale set and its listener
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners
kubectl get ephemeralrunners -n arc-runners

# Credentials present and populated
kubectl get externalsecret arc-github-app -n arc-runners
kubectl get secret arc-github-app -n arc-runners -o jsonpath='{.data}' | jq 'keys'

# The runner identity
kubectl get sa arc-runner -n arc-runners -o yaml | grep role-arn
```

| Symptom | Likely cause |
|---------|--------------|
| No `arc-runner-scale-set` Application at all | `github-runners` label is not `enabled` — `github_config_url` was empty at bootstrap |
| Chart fails with "No gha-rs-controller deployment found" | `controllerServiceAccount` not set, or the controller's `releaseName` changed |
| Listener crash-loops with 401/404 | App credentials wrong, or the App is not installed on the org/repo in `github_config_url` |
| Runners never start, listener healthy | No Karpenter capacity for `app=workload`, or `maxRunners` reached |
| `docker build` fails with "cannot connect" | BuildKit sidecar not ready — check `BUILDKIT_HOST` and the `buildkitd` container logs |
