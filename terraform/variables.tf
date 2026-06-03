variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "simple-eks"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/24"
}

variable "azs" {
  description = "List of availability zones"
  type        = list(string)
  default = [
    "ap-south-1a",
    "ap-south-1b"
  ]
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
  default = [
    "10.0.0.0/26",
    "10.0.0.64/26"
  ]
}

variable "private_subnets" {
  description = "List of private subnet CIDR blocks"
  type        = list(string)
  default = [
    "10.0.0.128/26",
    "10.0.0.192/26"
  ]
}

variable "instance_type" {
  description = "EC2 instance type for the node group"
  type        = string
  default     = "m6a.large"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project   = "simple-eks"
    ManagedBy = "Terraform"
  }
}

locals {
  common_tags = merge(var.tags, {
    Environment = var.environment
  })
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of EKS worker nodes"
  default     = 2
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of EKS worker nodes"
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of EKS worker nodes"
  default     = 2
}


variable "domain_name" {
  description = "Route53 Domain Name"
  type        = string
}

variable "argocd_admin_password_plaintext" {
  description = "Plain Argo CD admin password stored in Secrets Manager for recovery"
  type        = string
  default     = null
  sensitive   = true
}

variable "argocd_admin_password_hash" {
  description = "Bcrypt hash of Argo CD admin password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "alertmanager_slack_webhook_url" {
  description = "Slack webhook URL for Alertmanager"
  type        = string
  default     = ""
  sensitive   = true
}

variable "environment" {
  description = "Deployment environment name (e.g. prod, staging)"
  type        = string
  default     = "prod"
}

variable "add_cluster_autoscaler_tags" {
  description = "Whether to add Cluster Autoscaler discovery tags to the node group"
  type        = bool
  default     = false
}

variable "enable_karpenter_discovery_tags" {
  description = "Whether to add Karpenter discovery tags to private subnets and node security group"
  type        = bool
  default     = false
}