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