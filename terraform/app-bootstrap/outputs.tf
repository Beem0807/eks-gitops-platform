output "vpc_id" {
  description = "Created VPC ID"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "Created EKS cluster name"
  value       = module.eks.cluster_name
}

output "application_nlb_hostname" {
  description = "Public hostname of the NLB"
  value       = try(data.kubernetes_service_v1.simple_time_service.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "application_url" {
  description = "Public URL of the application"
  value       = try("http://${data.kubernetes_service_v1.simple_time_service.status[0].load_balancer[0].ingress[0].hostname}", null)
}