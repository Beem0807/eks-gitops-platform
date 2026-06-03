data "aws_iam_policy_document" "external_dns" {
  #checkov:skip=CKV_AWS_356: route53:List* actions do not support resource-level ARNs in AWS
  statement {
    sid    = "ExternalDNSChangeRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets"
    ]

    resources = [
      "arn:aws:route53:::hostedzone/*"
    ]
  }

  statement {
    sid    = "ExternalDNSListZones"
    effect = "Allow"

    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns"
  description = "IRSA policy for ExternalDNS Route53 access"
  policy      = data.aws_iam_policy_document.external_dns.json

  tags = local.common_tags
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.cluster_name}-external-dns-irsa"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  policies = {
    external_dns = aws_iam_policy.external_dns.arn
  }

  tags = local.common_tags
}