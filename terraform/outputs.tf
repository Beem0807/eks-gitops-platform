output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "domain_name" {
  description = "Route53 Domain Name"
  value       = var.domain_name
}

output "karpenter_instance_profile_name" {
  value = module.karpenter.instance_profile_name
}

output "thanos_bucket_name" {
  value = aws_s3_bucket.thanos.bucket
}

output "loki_bucket_name" {
  value = aws_s3_bucket.loki.bucket
}

output "velero_bucket_name" {
  value = aws_s3_bucket.velero.bucket
}

output "tempo_bucket_name" {
  value = aws_s3_bucket.tempo.bucket
}

output "mlops_pipeline_role_arn" {
  description = "IRSA role for MLOps pipeline workloads (mlops-system, kubeflow) - S3 and SQS read/write"
  value       = aws_iam_role.mlops_pipeline.arn
}

output "mlops_serving_role_arn" {
  description = "IRSA role for KServe predictors (mlops) - S3 read-only"
  value       = aws_iam_role.mlops_serving.arn
}

output "arc_runner_role_arn" {
  description = "IRSA role assumed by GitHub Actions runner pods"
  value       = aws_iam_role.arc_runner.arn
}

output "github_config_url" {
  description = "GitHub org or repo the platform runner scale set registers with. Empty disables the scale set."
  value       = var.github_config_url
}
