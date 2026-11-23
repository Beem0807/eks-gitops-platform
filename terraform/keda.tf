# ──────────────────────────────────────────────────────────────────────────────
# KEDA - event-driven autoscaling
# ──────────────────────────────────────────────────────────────────────────────
#
# KEDA exists here for one reason that a HorizontalPodAutoscaler cannot cover:
# scaling to and from zero on queue depth. The MLOps ingestion worker handles
# dataset uploads, which arrive rarely - days or weeks apart. The alternatives
# were both worse:
#
#   a Deployment polling SQS   - a pod idles for days holding a node slot, and
#                                Karpenter cannot consolidate the node it sits
#                                on, so the cost is a node, not a pod.
#   a CronJob                  - costs nothing idle, but pickup latency is the
#                                schedule interval. At 15 minutes that is
#                                visible in a demo and arbitrary in production.
#
# KEDA gives zero pods when the queue is empty and a Job within its polling
# interval when a message lands.
#
# The role below is narrow on purpose: KEDA only ever READS queue depth. It
# never receives, deletes, or sends a message - the worker's own role does
# that, and the worker is what the Job runs as. So this role gets exactly the
# three read attributes the SQS scaler calls, on exactly the queues it scales.
#
# The controller is installed for every cluster, not only MLOps ones, because
# event-driven autoscaling is a platform capability rather than an MLOps
# feature - the same argument as Karpenter. The ScaledJob that uses it lives in
# the MLOps repository, so an EKS-only cluster runs an idle controller and no
# scaled workloads.

locals {
  keda_namespace = "keda"

  # The operator's ServiceAccount, fixed by the chart. Pinned here rather than
  # derived, because a Pod Identity association names a ServiceAccount that may
  # not exist yet - a typo produces no error at apply time and no credentials
  # at run time, which surfaces as an unexplained scaler auth failure.
  keda_operator_service_account = "keda-operator"

  # Queues KEDA is allowed to inspect. Scoped to the fraud-detection ingestion
  # pair rather than "*": a wildcard here would let any ScaledObject in any
  # namespace enumerate the depth of every queue in the account, including
  # Karpenter's interruption queue.
  keda_scalable_queue_arns = [
    "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:fraud-detection-ingestion",
    "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:fraud-detection-ingestion-dlq",
  ]
}

data "aws_iam_policy_document" "keda_operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "keda_operator" {
  statement {
    sid    = "ReadQueueDepth"
    effect = "Allow"

    # The SQS scaler reads ApproximateNumberOfMessages,
    # ApproximateNumberOfMessagesNotVisible and
    # ApproximateNumberOfMessagesDelayed. All three come from one API call.
    actions = ["sqs:GetQueueAttributes"]

    resources = local.keda_scalable_queue_arns
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${var.cluster_name}-keda-operator"
  description        = "Read SQS queue depth for KEDA scalers. No message access."
  assume_role_policy = data.aws_iam_policy_document.keda_operator_trust.json

  tags = merge(local.common_tags, {
    Component = "keda"
  })
}

resource "aws_iam_role_policy" "keda_operator" {
  name   = "read-queue-depth"
  role   = aws_iam_role.keda_operator.id
  policy = data.aws_iam_policy_document.keda_operator.json
}

resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.keda_namespace
  service_account = local.keda_operator_service_account
  role_arn        = aws_iam_role.keda_operator.arn

  tags = local.common_tags
}
