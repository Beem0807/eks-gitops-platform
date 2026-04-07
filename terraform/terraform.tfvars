aws_region = "ap-south-1"

vpc_name = "eks-vpc"

cluster_name = "simple-eks"

vpc_cidr = "10.0.0.0/24"

public_subnets = [
  "10.0.0.0/26",
  "10.0.0.64/26"
]

private_subnets = [
  "10.0.0.128/26",
  "10.0.0.192/26"
]

instance_type = "m6a.large"

node_desired_size = 2
node_min_size     = 2
node_max_size     = 2