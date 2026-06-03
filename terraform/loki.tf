resource "aws_s3_bucket" "loki" {
  bucket = "${var.cluster_name}-loki-logs-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-loki-logs"
  })
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid    = "LokiBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      aws_s3_bucket.loki.arn
    ]
  }

  statement {
    sid    = "LokiObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]

    resources = [
      "${aws_s3_bucket.loki.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "loki_s3" {
  name        = "${var.cluster_name}-loki-s3"
  description = "S3 access policy for Loki object storage"
  policy      = data.aws_iam_policy_document.loki_s3.json

  tags = local.common_tags
}

module "loki_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-loki-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["logging:loki"]
    }
  }

  policies = {
    loki_s3 = aws_iam_policy.loki_s3.arn
  }

  tags = local.common_tags
}
