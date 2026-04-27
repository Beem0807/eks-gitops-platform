variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "azs" {
  description = "List of availability zones"
  type        = list(string)
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
}

variable "private_subnets" {
  description = "List of private subnet CIDR blocks"
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "enable_karpenter_discovery_tags" {
  description = "Whether to add Karpenter discovery tags to private subnets"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "EKS cluster name used for Karpenter discovery tags. Required only when enable_karpenter_discovery_tags is true."
  type        = string
  default     = null

  validation {
    condition = (
      !var.enable_karpenter_discovery_tags ||
      (
        var.cluster_name != null &&
        trimspace(var.cluster_name) != ""
      )
    )

    error_message = "cluster_name must be provided when enable_karpenter_discovery_tags is true."
  }
}