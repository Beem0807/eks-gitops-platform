data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ExternalSecretsReadTaggedSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]

    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ExternalSecret"
      values   = ["true"]
    }
  }
}


resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "IRSA policy for External Secrets Operator"
  policy      = data.aws_iam_policy_document.external_secrets.json

  tags = var.tags
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-external-secrets-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  policies = {
    external_secrets = aws_iam_policy.external_secrets.arn
  }

  tags = var.tags
}