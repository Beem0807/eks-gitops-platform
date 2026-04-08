variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "ap-south-1"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
  default     = "simple-eks"
}

variable "vpc_name" {
  type        = string
  description = "VPC name"
  default     = "eks-vpc"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.0.0.0/24"
}

variable "azs" {
  type        = list(string)
  description = "Availability zones"
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnets" {
  type        = list(string)
  description = "Public subnet CIDRs"
  default     = ["10.0.0.0/26", "10.0.0.64/26"]
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnet CIDRs"
  default     = ["10.0.0.128/26", "10.0.0.192/26"]
}

variable "instance_type" {
  type        = string
  description = "EKS worker instance type"
  default     = "m6a.large"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "app_namespace" {
  type        = string
  description = "Namespace for the app"
  default     = "simple-time-service"
}

variable "app_image_repository" {
  type        = string
  description = "Docker image repository"
  default     = "docker.io/nabeemdev/simple-time-service"
}

variable "app_image_tag" {
  type        = string
  description = "Docker image tag"
  default     = "v1"
}