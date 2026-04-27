resource "aws_s3_bucket" "thanos" {
  bucket = "${var.cluster_name}-thanos-metrics-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-thanos-metrics"
  })
}

resource "aws_s3_bucket_versioning" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "thanos_s3" {
  statement {
    sid    = "ThanosBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      aws_s3_bucket.thanos.arn
    ]
  }

  statement {
    sid    = "ThanosObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]

    resources = [
      "${aws_s3_bucket.thanos.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "thanos_s3" {
  name        = "${var.cluster_name}-thanos-s3"
  description = "S3 access policy for Thanos object storage"
  policy      = data.aws_iam_policy_document.thanos_s3.json

  tags = var.tags
}

module "thanos_prometheus_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-thanos-prometheus-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn

      namespace_service_accounts = [
        "monitoring:prometheus-kube-prometheus-prometheus"
      ]
    }
  }

  policies = {
    thanos_s3 = aws_iam_policy.thanos_s3.arn
  }

  tags = var.tags
}

module "thanos_components_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-thanos-components-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn

      namespace_service_accounts = [
        "monitoring:thanos-compactor",
        "monitoring:thanos-storegateway"
      ]
    }
  }

  policies = {
    thanos_s3 = aws_iam_policy.thanos_s3.arn
  }

  tags = var.tags
}