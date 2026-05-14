variable "aws_region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "simple-eks"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  default = "10.0.0.0/24"
}

variable "azs" {
  default = [
    "ap-south-1a",
    "ap-south-1b"
  ]
}

variable "public_subnets" {
  default = [
    "10.0.0.0/26",
    "10.0.0.64/26"
  ]
}

variable "private_subnets" {
  default = [
    "10.0.0.128/26",
    "10.0.0.192/26"
  ]
}

variable "instance_type" {
  default = "m6a.large"
}

variable "tags" {
  default = {
    Project   = "simple-eks"
    ManagedBy = "Terraform"
  }
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

variable "enable_nlb_nodeport_rule" {
  description = "Enable node security group rule for NodePort access from NLB"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name used in Argo CD cluster metadata"
  type        = string
  default     = "prod"
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

variable "policy_reporter_basic_auth_username" {
  description = "Policy Reporter UI basic auth username"
  type        = string
  default     = "admin"
}

variable "policy_reporter_basic_auth_password" {
  description = "Policy Reporter UI basic auth password"
  type        = string
  default     = ""
  sensitive   = true
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