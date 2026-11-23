# Crossplane AWS provider identity and permissions.
#
# Each Crossplane provider pod runs under its own ServiceAccount (pinned to a
# stable name by the DeploymentRuntimeConfigs in
# gitops/infrastructure/crossplane/crossplane-providers.yaml) and receives AWS
# credentials through EKS Pod Identity - the same mechanism Karpenter already
# uses. Pod Identity is preferred over IRSA here because the provider
# ServiceAccounts are created by the Crossplane package manager, not by Helm, so
# there is no chart value to hang an IRSA annotation off: with Pod Identity the
# binding lives entirely in AWS and needs nothing on the Kubernetes object.
#
# One role per AWS service provider. provider-aws-s3 cannot touch ECR,
# provider-aws-ecr cannot touch SQS.
#
# ── Scoping: broad allow, explicit deny on Terraform-owned resources ─────────
#
# Within its own service each role is allowed account-wide, with no name-prefix
# condition. Consuming projects write the provider's managed resources directly
# and choose their own resource names, so there is nothing stable for IAM to key
# a prefix on, and forcing a naming convention would push that constraint onto
# every consuming repository.
#
# What is constrained is the other direction: everything Terraform provisions is
# explicitly denied. Terraform stamps local.crossplane_denied_tags onto the
# Thanos, Loki, Velero, and Tempo buckets and the Karpenter interruption queue,
# and each policy below carries a Deny statement keyed on that tag. An explicit
# deny in IAM cannot be overridden by any allow in any policy, so no manifest -
# accidental or hostile - can make these roles delete the metric store, the log
# store, the backup bucket, the trace store, or the queue Karpenter relies on
# for spot interruption handling.
#
# Protecting a new Terraform-created S3 bucket, ECR repository, or SQS queue is
# therefore a one-line change: merge local.crossplane_denied_tags into its tags.
#
# The deny conditions use s3:BucketTag for S3 and aws:ResourceTag for ECR and
# SQS. s3:BucketTag is the S3-specific key for a bucket's own tags and, unlike
# aws:ResourceTag, it also applies to object-level actions - so the deny covers
# the objects inside a protected bucket, not only the bucket itself. Without
# that, forceDestroy could still empty the Thanos bucket.
#
# The service boundary holds independently of the tags: provider-aws-s3 has no
# ECR or SQS permissions, and none of the three roles can reach IAM, EC2, or any
# other service.

locals {
  crossplane_namespace = "crossplane-system"

  # Marks a resource as off limits to the Crossplane provider roles. Merged into
  # the tags of every Terraform-created S3 bucket and SQS queue, and matched by
  # the Deny statements in the policies below. A dedicated key is used rather
  # than reusing ManagedBy so that the intent is explicit at both ends and
  # changing the ManagedBy convention cannot silently widen Crossplane's access.
  crossplane_denied_tags = {
    CrossplaneAccess = "deny"
  }

  crossplane_denied_tag_key   = "CrossplaneAccess"
  crossplane_denied_tag_value = "deny"
}

data "aws_iam_policy_document" "crossplane_pod_identity_trust" {
  statement {
    sid    = "AllowEksPodIdentity"
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# provider-aws-s3
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "crossplane_s3" {
  #checkov:skip=CKV_AWS_111: write actions are unconstrained by design - consuming projects name their own buckets, so there is no prefix or tag to condition on. Terraform-owned buckets are carved out by the explicit Deny statement below.
  #checkov:skip=CKV_AWS_356: S3 bucket ARNs are global (no account or region component), so "arn:aws:s3:::*" is the only expressible scope for account-wide bucket management. Scoping is enforced by the Deny statement, not the allow.
  statement {
    sid    = "CrossplaneManageBuckets"
    effect = "Allow"

    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketAcl",
      "s3:PutBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      # Required to enable EventBridge notifications on a bucket, which is what
      # the dataset ingestion flow in the MLOps platform is triggered by.
      "s3:PutBucketNotification",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetAnalyticsConfiguration",
      "s3:GetMetricsConfiguration",
      "s3:GetIntelligentTieringConfiguration",
      "s3:GetInventoryConfiguration"
    ]

    resources = ["arn:aws:s3:::*"]
  }

  # Emptying a bucket on delete (forceDestroy). Object-level actions are kept in
  # their own statement so the blast radius of the object permissions is visible
  # rather than buried in the list above.
  statement {
    sid    = "CrossplaneDrainBucketsOnDelete"
    effect = "Allow"

    actions = [
      "s3:ListBucketVersions",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion"
    ]

    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*"
    ]
  }


  # Hard boundary around the Terraform-managed object stores. Covers both the
  # buckets and their objects, so neither the bucket nor its contents can be
  # deleted through these credentials.
  statement {
    sid    = "DenyTerraformOwnedBuckets"
    effect = "Deny"

    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/${local.crossplane_denied_tag_key}"
      values   = [local.crossplane_denied_tag_value]
    }
  }
}

resource "aws_iam_policy" "crossplane_s3" {
  name        = "${var.cluster_name}-crossplane-s3"
  description = "Crossplane provider-aws-s3 - manage S3 buckets in this account"
  policy      = data.aws_iam_policy_document.crossplane_s3.json

  tags = local.common_tags
}

resource "aws_iam_role" "crossplane_s3" {
  name               = "${var.cluster_name}-crossplane-s3"
  description        = "Assumed by the Crossplane provider-aws-s3 pod via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.crossplane_pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane_s3" {
  role       = aws_iam_role.crossplane_s3.name
  policy_arn = aws_iam_policy.crossplane_s3.arn
}

resource "aws_eks_pod_identity_association" "crossplane_s3" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.crossplane_namespace
  service_account = "provider-aws-s3"
  role_arn        = aws_iam_role.crossplane_s3.arn

  tags = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# provider-aws-ecr
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "crossplane_ecr" {
  #checkov:skip=CKV_AWS_111: write actions are unconstrained by design - consuming projects name their own repositories. Terraform-owned repositories are carved out by the explicit Deny statement below.
  #checkov:skip=CKV_AWS_356: scoped to repository/* in a single account and region; a narrower ARN would impose a naming convention on every consuming repository.
  statement {
    sid    = "CrossplaneManageRepositories"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:ListTagsForResource",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:PutImageTagMutability",
      "ecr:PutImageScanningConfiguration",
      "ecr:GetLifecyclePolicy",
      "ecr:PutLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy",
      "ecr:BatchDeleteImage",
      "ecr:ListImages"
    ]

    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"
    ]
  }


  # No Terraform-created ECR repository exists today. The statement is kept so
  # that protecting one later is purely a matter of tagging it, with no IAM
  # change needed.
  statement {
    sid    = "DenyTerraformOwnedRepositories"
    effect = "Deny"

    actions = ["ecr:*"]

    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.crossplane_denied_tag_key}"
      values   = [local.crossplane_denied_tag_value]
    }
  }
}

resource "aws_iam_policy" "crossplane_ecr" {
  name        = "${var.cluster_name}-crossplane-ecr"
  description = "Crossplane provider-aws-ecr - manage ECR repositories in ${var.aws_region}"
  policy      = data.aws_iam_policy_document.crossplane_ecr.json

  tags = local.common_tags
}

resource "aws_iam_role" "crossplane_ecr" {
  name               = "${var.cluster_name}-crossplane-ecr"
  description        = "Assumed by the Crossplane provider-aws-ecr pod via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.crossplane_pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane_ecr" {
  role       = aws_iam_role.crossplane_ecr.name
  policy_arn = aws_iam_policy.crossplane_ecr.arn
}

resource "aws_eks_pod_identity_association" "crossplane_ecr" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.crossplane_namespace
  service_account = "provider-aws-ecr"
  role_arn        = aws_iam_role.crossplane_ecr.arn

  tags = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# provider-aws-sqs
# ──────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "crossplane_sqs" {
  #checkov:skip=CKV_AWS_111: write actions are unconstrained by design - consuming projects name their own queues. The Karpenter interruption queue is carved out by the explicit Deny statement below.
  #checkov:skip=CKV_AWS_356: scoped to a single account and region; a narrower ARN would impose a naming convention on every consuming repository.
  statement {
    sid    = "CrossplaneManageQueues"
    effect = "Allow"

    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
      "sqs:SetQueueAttributes",
      "sqs:ListQueueTags",
      "sqs:TagQueue",
      "sqs:UntagQueue"
    ]

    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
    ]
  }


  # Karpenter's spot interruption queue carries the tag. Deleting or
  # reconfiguring it would silently stop node interruption handling, so it is
  # placed out of reach rather than left to convention.
  statement {
    sid    = "DenyTerraformOwnedQueues"
    effect = "Deny"

    actions = ["sqs:*"]

    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.crossplane_denied_tag_key}"
      values   = [local.crossplane_denied_tag_value]
    }
  }
}

resource "aws_iam_policy" "crossplane_sqs" {
  name        = "${var.cluster_name}-crossplane-sqs"
  description = "Crossplane provider-aws-sqs - manage SQS queues in ${var.aws_region}"
  policy      = data.aws_iam_policy_document.crossplane_sqs.json

  tags = local.common_tags
}

resource "aws_iam_role" "crossplane_sqs" {
  name               = "${var.cluster_name}-crossplane-sqs"
  description        = "Assumed by the Crossplane provider-aws-sqs pod via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.crossplane_pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane_sqs" {
  role       = aws_iam_role.crossplane_sqs.name
  policy_arn = aws_iam_policy.crossplane_sqs.arn
}

resource "aws_eks_pod_identity_association" "crossplane_sqs" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.crossplane_namespace
  service_account = "provider-aws-sqs"
  role_arn        = aws_iam_role.crossplane_sqs.arn

  tags = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# provider-aws-cloudwatchevents (EventBridge)
# ──────────────────────────────────────────────────────────────────────────────
#
# EventBridge is the S3-to-SQS hop in the MLOps dataset ingestion flow:
#
#   S3 upload -> EventBridge rule -> SQS -> in-cluster ingestion worker
#
# EventBridge rather than an S3 bucket notification pointing straight at SQS:
# a bucket's notification configuration is a single resource, so a second
# consumer later means editing the one object that the first consumer owns.
# Enabling EventBridge on the bucket once and matching events with rules lets
# consumers be added and removed independently.
#
# Note the provider name. Upjet derives groups from Terraform resource names,
# and EventBridge rules are `aws_cloudwatch_event_rule` - so the API group is
# cloudwatchevents.aws.m.upbound.io, not eventbridge.

data "aws_iam_policy_document" "crossplane_events" {
  #checkov:skip=CKV_AWS_111: write actions are unconstrained by design - consuming projects name their own rules. Terraform-owned rules are carved out by the explicit Deny statement below.
  #checkov:skip=CKV_AWS_356: scoped to rules on the default event bus in a single account and region; a narrower ARN would impose a naming convention on every consuming repository.

  statement {
    sid    = "CrossplaneManageEventRules"
    effect = "Allow"

    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:EnableRule",
      "events:DisableRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:ListTagsForResource",
      "events:TagResource",
      "events:UntagResource"
    ]

    resources = [
      "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/*"
    ]
  }

  # events:ListRules is bus-scoped rather than rule-scoped, so it cannot be
  # narrowed to a rule ARN. It is read-only metadata.
  statement {
    sid    = "CrossplaneListEventRules"
    effect = "Allow"

    actions = ["events:ListRules"]

    resources = [
      "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
    ]
  }

  statement {
    sid    = "DenyTerraformOwnedEventRules"
    effect = "Deny"

    actions = ["events:*"]

    resources = [
      "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.crossplane_denied_tag_key}"
      values   = [local.crossplane_denied_tag_value]
    }
  }
}

resource "aws_iam_policy" "crossplane_events" {
  name        = "${var.cluster_name}-crossplane-events"
  description = "Crossplane provider-aws-cloudwatchevents - manage EventBridge rules and targets in ${var.aws_region}"
  policy      = data.aws_iam_policy_document.crossplane_events.json

  tags = local.common_tags
}

resource "aws_iam_role" "crossplane_events" {
  name               = "${var.cluster_name}-crossplane-events"
  description        = "Assumed by the Crossplane provider-aws-cloudwatchevents pod via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.crossplane_pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane_events" {
  role       = aws_iam_role.crossplane_events.name
  policy_arn = aws_iam_policy.crossplane_events.arn
}

resource "aws_eks_pod_identity_association" "crossplane_events" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.crossplane_namespace
  service_account = "provider-aws-cloudwatchevents"
  role_arn        = aws_iam_role.crossplane_events.arn

  tags = local.common_tags
}
