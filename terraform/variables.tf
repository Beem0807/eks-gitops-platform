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