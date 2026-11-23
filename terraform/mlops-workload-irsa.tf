# IRSA roles for MLOps application pods.
#
# Crossplane provisions the buckets and queues; these are what let workloads
# read and write them at runtime. Separate concerns, separate identities - the
# Crossplane provider roles are a control plane (create/configure/delete) and
# hold no data-plane permissions at all.
#
# ── Two roles, split read/write from read-only ───────────────────────────────
#
# A single shared role would be simpler, and it is what this started as. It was
# split because the workloads do not need the same thing, and one of them is
# materially more exposed than the rest:
#
#   pipeline (read/write)  Kubeflow Pipelines, MLflow, the ingestion worker,
#                          the Evidently monitoring job. These produce data -
#                          artifacts, dataset versions, monitoring reports - so
#                          they need write and delete, and the ingestion worker
#                          needs SQS.
#
#   serving (read-only)    The KServe predictor. It runs model code and handles
#                          external inference requests, which makes it the most
#                          exposed workload in the platform, and all it needs is
#                          to download one model artifact. Under a shared role
#                          it would also hold s3:DeleteObject on the dataset
#                          bucket - so a compromised predictor could delete
#                          every dataset. It now cannot write anything at all.
#
# The split falls exactly on a namespace boundary that already exists: `mlops`
# is the serving namespace, `mlops-system` and `kubeflow` are platform and
# pipelines. So the identity boundary needs no new convention to enforce it.
#
# Deliberately NOT split further - no role per component. That would require
# per-ServiceAccount trust policies, which reintroduces the problem IRSA was
# chosen to avoid: Kubeflow Pipelines alone creates 16 ServiceAccounts whose
# names change between releases, and each would need a Terraform change. The
# read/write versus read-only boundary is where the real risk reduction is.
#
# ── Why the policies name no resources ──────────────────────────────────────
#
# Terraform cannot reference a bucket Crossplane has not created yet, and
# chasing that with a Terraform change per bucket would defeat self-service
# provisioning. It does not have to: every S3 and SQS data-plane action supports
# tag conditions, and for S3 the s3:BucketTag key applies to object-level
# actions as well as bucket-level ones.
#
# So the grant is a tag match. Tagging a Crossplane-provisioned bucket
# Workload=mlops is what brings it into scope - no IAM change, no Terraform run.
#
# The tag is therefore doing authorisation work, which is worth stating plainly:
# whoever can set tags on a Crossplane resource can bring it into scope. Nothing
# enforces the tag, so a bucket created without it is simply unreadable -
# AccessDenied, which is the safe direction to fail.
#
# ── Why IRSA rather than Pod Identity ───────────────────────────────────────
#
# Deliberately opposite to the Crossplane providers, which use Pod Identity. A
# Pod Identity association is an exact namespace/ServiceAccount pair and cannot
# wildcard. The trust policies below use StringLike on a namespace, so a
# consuming repository names its own ServiceAccounts without a platform change.
#
# Note that the trust policy is the *permission to assume*; the actual grant is
# the eks.amazonaws.com/role-arn annotation on a ServiceAccount. A pod whose
# ServiceAccount carries no annotation gets no credentials even though the trust
# policy would allow it. That keeps the opt-in in the consuming repository.

locals {
  # Derived from the OIDC provider ARN rather than taking a new module output,
  # so this does not depend on an upstream output name.
  # arn:aws:iam::<acct>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<id>
  oidc_provider_url = split("oidc-provider/", module.eks.oidc_provider_arn)[1]

  # Namespaces whose pods may assume the read/write pipeline role. These must
  # stay in step with the destinations the mlops AppProject permits, in
  # optional/mlops/.
  #
  # kubeflow is separate from mlops-system because Kubeflow Pipelines' upstream
  # Kustomize overlay hardcodes `namespace: kubeflow` and warns that moving it
  # also requires patching a cluster-scoped ClusterRoleBinding, whose subject
  # namespace the kustomize namespace transformer does not rewrite.
  mlops_pipeline_namespaces = [
    "mlops-system",
    "kubeflow"
  ]

  # Namespace whose pods may assume the read-only serving role.
  mlops_serving_namespaces = [
    "mlops"
  ]

  # The tag that grants access. Must match the tags on the Crossplane manifests
  # in the consuming repository.
  mlops_workload_tag_key   = "Workload"
  mlops_workload_tag_value = "mlops"
}

# ──────────────────────────────────────────────────────────────────────────────
# Pipeline role - read/write
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "mlops_pipeline_trust" {
  statement {
    sid    = "AllowMlopsPipelineServiceAccounts"
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike, not StringEquals - this is what allows the namespace wildcard.
    # The terraform-aws-modules iam-role-for-service-accounts module used
    # elsewhere in this directory emits StringEquals on sub and cannot express
    # this, which is why these roles are written out longhand.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = [for ns in local.mlops_pipeline_namespaces : "system:serviceaccount:${ns}:*"]
    }
  }
}

data "aws_iam_policy_document" "mlops_pipeline" {
  #checkov:skip=CKV_AWS_111: resource ARNs are necessarily wildcards - the policy authorises by tag because the resources are provisioned by Crossplane after this role exists. Access is bounded by the Workload tag condition on every statement.
  #checkov:skip=CKV_AWS_356: same reason. S3 bucket ARNs are also global, so arn:aws:s3:::* is the only expressible scope.

  # Dataset, artifact and monitoring-report objects. s3:BucketTag refers to the
  # containing bucket's tags and is valid on object-level actions, which is what
  # makes a tag-scoped object policy possible at all.
  statement {
    sid    = "MlopsPipelineObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]

    resources = ["arn:aws:s3:::*/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }

  # Listing is a bucket-level action, so it needs the bucket ARN rather than the
  # object ARN. Without it, SDKs that enumerate a prefix before reading fail -
  # which includes DVC resolving a dataset revision and MLflow listing an
  # artifact directory.
  statement {
    sid    = "MlopsPipelineBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation"
    ]

    resources = ["arn:aws:s3:::*"]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }

  # Dataset ingestion queue. Only the ingestion worker uses this, but it runs in
  # mlops-system alongside the other pipeline workloads, and splitting a third
  # role for one consumer is not worth a per-ServiceAccount trust policy.
  statement {
    sid    = "MlopsPipelineQueueAccess"
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }
}

resource "aws_iam_policy" "mlops_pipeline" {
  name        = "${var.cluster_name}-mlops-pipeline"
  description = "Read/write access for MLOps pipeline workloads - S3 and SQS resources tagged ${local.mlops_workload_tag_key}=${local.mlops_workload_tag_value}"
  policy      = data.aws_iam_policy_document.mlops_pipeline.json

  tags = local.common_tags
}

resource "aws_iam_role" "mlops_pipeline" {
  name               = "${var.cluster_name}-mlops-pipeline"
  description        = "Assumed via IRSA by ServiceAccounts in the mlops-system and kubeflow namespaces"
  assume_role_policy = data.aws_iam_policy_document.mlops_pipeline_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "mlops_pipeline" {
  role       = aws_iam_role.mlops_pipeline.name
  policy_arn = aws_iam_policy.mlops_pipeline.arn
}

# ──────────────────────────────────────────────────────────────────────────────
# Serving role - read-only
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "mlops_serving_trust" {
  statement {
    sid    = "AllowMlopsServingServiceAccounts"
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = [for ns in local.mlops_serving_namespaces : "system:serviceaccount:${ns}:*"]
    }
  }
}

data "aws_iam_policy_document" "mlops_serving" {
  #checkov:skip=CKV_AWS_356: S3 bucket ARNs are global, so arn:aws:s3:::* is the only expressible scope. Access is bounded by the Workload tag condition. The single write action, PutObject, is further scoped to the observations/ prefix - see MlopsServingWritePayloadLogs.

  # Reading a model artifact. KServe's storage-initializer lists the model
  # prefix and then downloads each object, so ListBucket is required alongside
  # GetObject - without it the init container fails before pulling anything.
  #
  # No PutObject, no DeleteObject, no multipart actions. A compromised predictor
  # pod cannot modify or destroy anything in these buckets.
  statement {
    sid    = "MlopsServingReadObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = ["arn:aws:s3:::*/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }

  # Payload logging, and ONLY payload logging.
  #
  # KServe v0.21's inference logger writes batched parquet payload logs
  # directly to blob storage (pkg/logger/store.go supports s3 and s3a), which
  # is how production traffic reaches the drift job. That logger runs inside
  # the predictor pod, so it carries this role - and the policy above grants no
  # write action at all, so without this statement the logger silently fails
  # every upload and the drift report has nothing to compare against.
  #
  # The concession is deliberately as small as it can be:
  #
  #   * PutObject alone. No DeleteObject, no DeleteObjectVersion, no
  #     PutObjectAcl, no multipart abort.
  #   * Scoped to the observations/ prefix by the resource pattern, so a
  #     compromised predictor cannot write a model artifact, a dataset, or
  #     anything else outside its own log prefix.
  #   * Still gated on the Workload tag, like every other statement here.
  #
  # The buckets are versioned, so even an overwrite inside observations/
  # retains the prior version. What this does NOT preserve is the previous
  # absolute claim that a compromised predictor cannot write anything; it can
  # now append to its own log prefix. That is the price of having production
  # data to detect drift with, and the alternative - a separate receiver
  # service holding the pipeline role - trades it for a component in the
  # prediction path.
  statement {
    sid    = "MlopsServingWritePayloadLogs"
    effect = "Allow"

    actions = [
      "s3:PutObject"
    ]

    resources = ["arn:aws:s3:::*/observations/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }

  statement {
    sid    = "MlopsServingListBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = ["arn:aws:s3:::*"]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.mlops_workload_tag_key}"
      values   = [local.mlops_workload_tag_value]
    }
  }
}

resource "aws_iam_policy" "mlops_serving" {
  name        = "${var.cluster_name}-mlops-serving"
  description = "Read-only model artifact access for KServe predictors - S3 resources tagged ${local.mlops_workload_tag_key}=${local.mlops_workload_tag_value}"
  policy      = data.aws_iam_policy_document.mlops_serving.json

  tags = local.common_tags
}

resource "aws_iam_role" "mlops_serving" {
  name               = "${var.cluster_name}-mlops-serving"
  description        = "Assumed via IRSA by ServiceAccounts in the mlops namespace - read-only"
  assume_role_policy = data.aws_iam_policy_document.mlops_serving_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "mlops_serving" {
  role       = aws_iam_role.mlops_serving.name
  policy_arn = aws_iam_policy.mlops_serving.arn
}
