resource "aws_s3_bucket" "velero" {
  bucket = "${var.cluster_name}-velero-backups-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-velero-backups"
  })
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "velero" {
  #checkov:skip=CKV_AWS_111: ec2:CreateSnapshot and ec2:Describe* do not support resource-level ARNs in AWS
  #checkov:skip=CKV_AWS_356: ec2:CreateSnapshot and ec2:Describe* do not support resource-level ARNs in AWS
  statement {
    sid    = "VeleroBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      aws_s3_bucket.velero.arn
    ]
  }

  statement {
    sid    = "VeleroObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]

    resources = [
      "${aws_s3_bucket.velero.arn}/*"
    ]
  }

  statement {
    sid    = "VeleroEC2Snapshots"
    effect = "Allow"

    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
      "ec2:CreateTags",
      "ec2:DescribeTags"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "velero" {
  name        = "${var.cluster_name}-velero"
  description = "IAM policy for Velero backups - S3 object storage and EBS snapshots"
  policy      = data.aws_iam_policy_document.velero.json

  tags = local.common_tags
}

module "velero_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-velero-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["velero:velero"]
    }
  }

  policies = {
    velero = aws_iam_policy.velero.arn
  }

  tags = local.common_tags
}
