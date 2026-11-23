# IRSA role for GitHub Actions runner pods.
#
# Needed so workflows can push images to ECR. Note what this is *not* for:
#
#   - Pulling images for pods is done by the node IAM role, which the Karpenter
#     module already grants ECR read. Nothing here is involved.
#   - Creating and configuring ECR repositories is the Crossplane provider role
#     in crossplane.tf. That role manages repositories and cannot push images;
#     this one pushes images and cannot create repositories.
#
# Three separate identities for three separate jobs, none of which can do
# another's work.
#
# The ServiceAccount is created by
# gitops/ci/actions-runner-controller/arc-runner-identity.yaml rather than by
# the runner scale set chart. The chart's own ServiceAccount name is derived
# from the Helm release name and carries no annotations, so it cannot hold an
# IRSA binding; the scale set sets template.spec.serviceAccountName to point at
# ours instead.
#
# Trust is an exact namespace/ServiceAccount pair, unlike the MLOps workload
# role which wildcards a namespace. arc-runners is shared infrastructure - a
# wildcard there would let any future runner scale set in that namespace push
# images, which is precisely what should require a deliberate change.
#
# ── Security note worth reading before widening this ────────────────────────
#
# A self-hosted runner executes workflow code, including code from pull
# requests if the repository is configured that way. Any AWS permission this
# role holds is therefore reachable by anyone who can open a PR. ECR push is
# already meaningful: it allows publishing a new tag. The convention in
# examples/crossplane/ sets imageTagMutability=IMMUTABLE so an existing tag
# cannot be overwritten, but nothing enforces that, and this role can push to
# any repository in the region.
#
# Narrow it by adding a tag condition keyed on aws:ResourceTag once the set of
# repositories runners publish to is known, and restrict which workflows run on
# self-hosted runners for public or fork-accepting repositories.

locals {
  arc_runner_namespace       = "arc-runners"
  arc_runner_service_account = "arc-runner"
}

data "aws_iam_policy_document" "arc_runner_trust" {
  statement {
    sid    = "AllowArcRunnerServiceAccount"
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
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.arc_runner_namespace}:${local.arc_runner_service_account}"]
    }
  }
}

data "aws_iam_policy_document" "arc_runner" {
  #checkov:skip=CKV_AWS_356: ecr:GetAuthorizationToken has no resource type and no condition keys in AWS - "*" is the only valid scope. It returns a registry token; the push and pull calls it enables are repository-scoped below.

  statement {
    sid    = "EcrAuth"
    effect = "Allow"

    actions = ["ecr:GetAuthorizationToken"]

    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages"
    ]

    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"
    ]
  }

  # Consistent with the Crossplane roles: anything Terraform provisions is out
  # of reach. No Terraform-created ECR repository exists today, so this is
  # forward-looking - tagging one is all that is needed to protect it.
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

resource "aws_iam_policy" "arc_runner" {
  name        = "${var.cluster_name}-arc-runner"
  description = "ECR push and pull for GitHub Actions runner pods"
  policy      = data.aws_iam_policy_document.arc_runner.json

  tags = local.common_tags
}

resource "aws_iam_role" "arc_runner" {
  name               = "${var.cluster_name}-arc-runner"
  description        = "Assumed via IRSA by the ${local.arc_runner_service_account} ServiceAccount in ${local.arc_runner_namespace}"
  assume_role_policy = data.aws_iam_policy_document.arc_runner_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "arc_runner" {
  role       = aws_iam_role.arc_runner.name
  policy_arn = aws_iam_policy.arc_runner.arn
}
