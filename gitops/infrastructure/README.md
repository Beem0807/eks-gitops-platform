# Infrastructure - Crossplane

Kubernetes-native provisioning of AWS infrastructure. Crossplane lets a
workload declare the S3 bucket, ECR repository, or SQS queue it needs as an
ordinary Kubernetes manifest, reconciled by the same GitOps loop as everything
else in the cluster - no Terraform run, no state file, and no AWS credentials in
the consuming repository.

The deployment is split across four ArgoCD Applications because each one needs
the previous to be healthy before it can succeed.

| Wave | ApplicationSet | What it installs |
|------|----------------|------------------|
| 11 | `crossplane` | Crossplane core and the RBAC manager, via the upstream Helm chart |
| 12 | `crossplane-providers` | The AWS provider packages and their DeploymentRuntimeConfigs |
| 12 | `crossplane-podmonitor` | Prometheus scrape config for Crossplane's own metrics |
| 13 | `crossplane-provider-config` | AWS credentials and the managed resource activation policy |

Crossplane is installed last, after the whole existing platform. Nothing in
waves -1 to 10 depends on it, so a failed Crossplane install cannot block
Prometheus, the ingress controller, or SimpleTimeService from coming up.

---

## Pinned versions

| Component | Version | Source |
|-----------|---------|--------|
| Crossplane | `2.4.3` | `https://charts.crossplane.io/stable` |
| AWS provider family | `v2.9.0` | `xpkg.upbound.io/upbound/provider-family-aws` |
| provider-aws-s3 | `v2.9.0` | `xpkg.upbound.io/upbound/provider-aws-s3` |
| provider-aws-ecr | `v2.9.0` | `xpkg.upbound.io/upbound/provider-aws-ecr` |
| provider-aws-sqs | `v2.9.0` | `xpkg.upbound.io/upbound/provider-aws-sqs` |
| provider-aws-cloudwatchevents | `v2.9.0` | `xpkg.upbound.io/upbound/provider-aws-cloudwatchevents` |

The AWS provider is published as a **family**: a shared package owns the
credential types, and one package per AWS service owns that service's managed
resources. Installing three service packages rather than a monolithic provider
is what keeps this to three small controllers instead of one process watching
every AWS service.

---

## Authentication - EKS Pod Identity

Each provider pod runs under its own ServiceAccount and gets its own IAM role:

| ServiceAccount (in `crossplane-system`) | IAM role | Can manage |
|------------------------------------------|----------|------------|
| `provider-aws-s3` | `<cluster>-crossplane-s3` | S3 buckets and their sub-resources |
| `provider-aws-ecr` | `<cluster>-crossplane-ecr` | ECR repositories and lifecycle policies |
| `provider-aws-sqs` | `<cluster>-crossplane-sqs` | SQS queues and redrive policies |
| `provider-aws-cloudwatchevents` | `<cluster>-crossplane-events` | EventBridge rules and targets |
| `provider-aws-family` | none | Serves the credential types only; makes no AWS calls |

Roles, policies, and `aws_eks_pod_identity_association` resources are in
[terraform/crossplane.tf](../../terraform/crossplane.tf). There is no Secret and
nothing to rotate - the binding lives entirely in AWS, keyed on the
namespace/ServiceAccount pair.

**Pod Identity rather than IRSA**, unlike most of this platform, for a concrete
reason: the provider ServiceAccounts are created by the Crossplane package
manager, not by Helm, so there is no chart value to attach an
`eks.amazonaws.com/role-arn` annotation to. Pod Identity needs nothing on the
Kubernetes object at all. Karpenter already uses the same mechanism.

### Why the DeploymentRuntimeConfigs exist

A Pod Identity association names a fixed ServiceAccount. Left to itself, the
Crossplane package manager derives the provider's ServiceAccount name from the
*provider revision*, so it changes on every provider upgrade - and AWS
authentication would silently break each time. The `DeploymentRuntimeConfig` per
provider pins the name. **Renaming a ServiceAccount there without updating
`terraform/crossplane.tf` breaks AWS auth for that provider.**

They also carry the node placement and resource limits, so provider pods land
on core nodes with the rest of the platform control plane.

### What the roles can and cannot reach

Each role is allowed its own service account-wide, with no name or tag
condition on the allow - consuming projects choose their own resource names, so
there is nothing stable for IAM to key a prefix on.

Everything Terraform provisions is then explicitly denied. Terraform stamps
`CrossplaneAccess=deny` on the Thanos, Loki, Velero, and Tempo buckets and the
Karpenter interruption queue, and each policy carries a matching `Deny`
statement. An explicit deny in IAM cannot be overridden by any allow, so no
manifest can make these roles touch the metric store, the log store, the backup
bucket, the trace store, or the queue Karpenter needs for spot interruption
handling.

Protecting a new Terraform-created bucket or queue is one line - merge
`local.crossplane_denied_tags` into its tags.

The S3 deny uses `s3:BucketTag` rather than `aws:ResourceTag` because, unlike
`aws:ResourceTag`, it also applies to object-level actions. Without that,
`forceDestroy` could still empty a protected bucket.

---

## Managed resource activation

Crossplane 2.x serves a provider's managed resource CRDs only when a
`ManagedResourceActivationPolicy` names them. The AWS provider family ships
roughly **2,100** managed resource types; activating all of them costs API
server memory and an informer per type, permanently, for types nothing uses.

The Crossplane Helm chart is therefore installed with
`provider.defaultActivations: []` - which would otherwise create a `*` policy -
and the explicit policy activates three groups by wildcard:

```
*.s3.aws.m.upbound.io
*.ecr.aws.m.upbound.io
*.sqs.aws.m.upbound.io
*.cloudwatchevents.aws.m.upbound.io
```

Around 80 CRDs instead of 2,100, while still letting consuming projects use any
resource type within those four services without a platform change.

EventBridge is `cloudwatchevents`, not `eventbridge` - upjet derives API groups
from Terraform resource names, and an EventBridge rule is
`aws_cloudwatch_event_rule`.

Only the **namespaced** variants (`*.aws.m.upbound.io`) are activated. The
cluster-scoped variants (`*.aws.upbound.io`) are left inactive so that every
Crossplane resource in the cluster lives in a namespace and is governed by that
namespace's RBAC.

Adding a fourth AWS service means three changes: install its provider package,
give it a role in `terraform/crossplane.tf`, and add its group here. Without the
activation entry its CRDs are never served and manifests fail with
`no matches for kind`.

---

## Using it

Consuming projects write the provider's managed resources directly. There is no
Crossplane Composition layer - see
[design decision #23](../../docs/design-decisions.md#23-direct-managed-resources-instead-of-compositions).

Worked examples for all three services:
[examples/crossplane/](../../examples/crossplane/).

```yaml
apiVersion: s3.aws.m.upbound.io/v1beta1
kind: Bucket
metadata:
  name: ml-datasets
  namespace: mlops
spec:
  forProvider:
    region: ap-south-1
    tags:
      Workload: mlops
```

`spec.providerConfigRef` defaults to
`{kind: ClusterProviderConfig, name: default}`, so it can be omitted.

> **Do not set `Validate=false` in `syncOptions`** on an Application that
> manages Crossplane resources. ArgoCD otherwise sends
> `fieldValidation=Strict`, so a misspelled field is rejected with a clear 400;
> with `Validate=false` it is dropped in silence and the resource comes up
> missing the setting. `kubeconform` cannot cover this gap - there is no public
> schema for the provider CRDs, so it skips these resources entirely. Use
> `kubectl apply --dry-run=server` to check a manifest against the CRDs actually
> installed.

---

## Verifying the install

```bash
# Providers must be INSTALLED and HEALTHY before anything else works
kubectl get providers.pkg.crossplane.io

# Credentials
kubectl get clusterproviderconfigs.aws.m.upbound.io

# Which managed resource CRDs are served
kubectl get managedresourceactivationpolicy platform-managed-resources -o yaml
kubectl api-resources --api-group=s3.aws.m.upbound.io

# Every Crossplane-managed AWS resource in the cluster, and its sync state
kubectl get managed
```

A managed resource that stays `SYNCED=False` is almost always IAM. The reason is
on the resource:

```bash
kubectl describe bucket.s3.aws.m.upbound.io <name> -n <namespace>
```

An `AccessDenied` mentioning a bucket or queue you did not create means the
`CrossplaneAccess=deny` boundary did its job.
