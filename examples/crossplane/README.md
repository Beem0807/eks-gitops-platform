# Crossplane examples

Reference manifests for the three AWS services the platform's Crossplane
providers support.

**Nothing here is deployed.** The root ArgoCD Application only recurses
`gitops/`, so files under `examples/` are never applied to the cluster. Copy
them into a consuming repository - for instance
[mlops-platform](https://github.com/Beem0807/mlops-platform) - and let that
repository's own ArgoCD Application own them.

| File | Resources |
|------|-----------|
| [s3-bucket.yaml](s3-bucket.yaml) | `Bucket` + encryption, versioning, public access block, lifecycle |
| [ecr-repository.yaml](ecr-repository.yaml) | `Repository` + `LifecyclePolicy` |
| [sqs-queue.yaml](sqs-queue.yaml) | `Queue` (primary) + `Queue` (DLQ) + `QueueRedrivePolicy` |

Prerequisite: the providers must be installed and healthy.

```bash
kubectl get providers.pkg.crossplane.io
```

---

## Read this before writing your own

### The API group has an `m` in it

```
s3.aws.m.upbound.io     ← use this (namespaced)
s3.aws.upbound.io       ← not served on this cluster (cluster-scoped)
```

Both exist in the provider. Only the namespaced variants are activated, so every
Crossplane resource lives in a namespace and is governed by that namespace's
RBAC. A manifest using the cluster-scoped group fails with `no matches for
kind`.

This matters more than it looks, because **most examples online use the
cluster-scoped group**, and the two differ in more than scope - see below.

### Object or array is not predictable

The namespaced API models some nested blocks as single objects where the
cluster-scoped API models them as single-element arrays. It is not consistent
even within one resource:

| Resource | Field | Shape |
|----------|-------|-------|
| `BucketVersioning` | `versioningConfiguration` | object |
| `BucketServerSideEncryptionConfiguration` | `rule` | array |
| `BucketServerSideEncryptionConfiguration` | `rule[].applyServerSideEncryptionByDefault` | **object** |
| `BucketLifecycleConfiguration` | `rule`, and every block inside it | array |
| `Repository` | `imageScanningConfiguration` | object |
| `Repository` | `encryptionConfiguration` | **array** |

Getting it wrong is caught, but only at sync time. Kubernetes always validates
field *types*, so an array where the schema expects an object is rejected with a
`400 Bad Request` and the ArgoCD Application goes `SyncFailed` with the field
named in the error. Unknown fields - a misspelling like `imageTagMutabilty` -
are rejected the same way, because ArgoCD sends `fieldValidation=Strict` on
apply.

> **Do not set `Validate=false` in `syncOptions` on an Application that manages
> Crossplane resources.** That switches ArgoCD to `fieldValidation=Ignore`, at
> which point an unknown field *is* dropped in silence: the resource is created,
> reports `READY=True`, and is simply missing the setting. A bucket meant to be
> versioned would come up unversioned with nothing in any log to say so. Type
> mismatches are still rejected either way.

Neither `kubeconform` nor `yamllint` checks these resources - there is no public
schema for the provider CRDs, so kubeconform skips them and reports success. To
check a field before committing, ask the cluster:

```bash
kubectl explain bucketversioning.spec.forProvider --api-version=s3.aws.m.upbound.io/v1beta1

# Or validate a whole file against the CRDs actually installed
kubectl apply --dry-run=server -f path/to/manifest.yaml
```

`--dry-run=server` is the authoritative check: it validates against the CRDs on
the cluster rather than against documentation, and kubectl defaults to
`--validate=strict`.

### Resource names are AWS names, not Kubernetes names

Sub-resources reference their parent by its **AWS** name:

```yaml
kind: BucketVersioning
spec:
  forProvider:
    bucket: ml-datasets     # the bucket's name in AWS
```

By default Crossplane uses `metadata.name` as the AWS name, so the two match.
Set `crossplane.io/external-name` to decouple them - as
[ecr-repository.yaml](ecr-repository.yaml) does, to group images under a
registry path - and remember that every reference must then use the external
name.

Some resources also accept `<field>Ref` / `<field>Selector` instead of a literal
name, which lets Crossplane resolve the dependency and order creation for you.
Support is per-field: `BucketVersioning` has `bucketRef` and `bucketSelector`,
and `QueueRedrivePolicy` has `queueUrlSelector`, but nothing resolves an ARN
embedded inside a JSON string field. Check the CRD.

### AWS defaults are not the safe-sounding ones

`BucketPublicAccessBlock` defaults **every** field to `false` when omitted, so
all four must be set explicitly. Omitting the resource entirely is safer than
writing a partial one, since new buckets get account-level Block Public Access
anyway.

SQS queues are **not** encrypted at rest unless asked -
`sqsManagedSseEnabled: true`. New S3 buckets, by contrast, are SSE-S3 encrypted
by default, and bucket versioning is **not** on by default.

### forceDestroy / forceDelete

Deleting a non-empty bucket or repository fails, and the managed resource then
sits stuck in deletion. `forceDestroy` (S3) and `forceDelete` (ECR) resolve it,
and both mean exactly what they say - leave them `false` for anything whose
contents should outlive the manifest.

---

## What the platform does not enforce

There is no Composition layer and no admission policy over these resources, so
the settings in these examples are **conventions, not guarantees**. A manifest
that omits encryption, sets `imageTagMutability: MUTABLE`, or skips the DLQ will
be accepted and applied.

What *is* enforced is in IAM: each provider role is confined to its own AWS
service, and everything Terraform provisions carries `CrossplaneAccess=deny`
and is unreachable. See
[gitops/infrastructure/README.md](../../gitops/infrastructure/README.md).

---

## Troubleshooting

```bash
# Everything Crossplane manages, with sync and ready state
kubectl get managed

# Why one resource is unhappy - the reason is in its conditions and events
kubectl describe bucket.s3.aws.m.upbound.io ml-datasets -n mlops
```

| Symptom | Likely cause |
|---------|--------------|
| `no matches for kind` | Cluster-scoped group used, or the service is not in the activation policy |
| `SYNCED=False`, `AccessDenied` | The resource is Terraform-owned (`CrossplaneAccess=deny`), or the provider lacks that action |
| `READY=True` but a setting is missing in AWS | Field was dropped - wrong shape or wrong name, on an Application with `Validate=false`. Re-check with `kubectl apply --dry-run=server` |
| Stuck `Terminating` | Bucket or repository is not empty and `forceDestroy`/`forceDelete` is false |
