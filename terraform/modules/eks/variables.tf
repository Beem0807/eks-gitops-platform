variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for the cluster and node groups"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type for the node group"
  type        = string
  default     = "m6a.large"
}

variable "node_min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Desired number of nodes in the node group"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "enable_nlb_nodeport_rule" {
  description = "Whether to allow external access to NodePort range on worker nodes"
  type        = bool
  default     = false
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