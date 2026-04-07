# EKS GitOps Platform

This repository contains two components:

1. **SimpleTimeService** — a minimal Python microservice containerized with Docker and deployable to Kubernetes.
2. **Terraform infrastructure** — an AWS VPC and EKS cluster provisioned with Terraform.

---

## SimpleTimeService

A minimal Python microservice that returns the current UTC timestamp and the caller's IP address as JSON.
The service is containerized with Docker, runs as a non-root user, and can be deployed to Kubernetes using a single manifest.

### Response format

```json
{
  "timestamp": "2026-04-07T12:00:00.000000+00:00",
  "ip": "203.0.113.42"
}
```

---

## Project structure

```
.
├── compose.yaml                   # Docker Compose for local development
├── k8s/
│   └── microservice.yaml          # Kubernetes Deployment + ClusterIP Service
├── sample-workload/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── .dockerignore
│   └── src/
│       └── app.py
└── terraform/                     # AWS infrastructure (VPC + EKS)
    ├── backend.tf                 # S3 remote state backend
    ├── main.tf                    # Root module — wires VPC and EKS modules
    ├── variables.tf               # Input variable declarations
    ├── terraform.tfvars           # Default variable values
    ├── outputs.tf                 # Root-level outputs
    ├── providers.tf               # AWS provider configuration
    ├── versions.tf                # Terraform and provider version constraints
    └── modules/
        ├── vpc/                   # VPC module (2 public + 2 private subnets)
        │   ├── main.tf
        │   ├── variables.tf
        │   └── outputs.tf
        └── eks/                   # EKS module (managed node group on private subnets)
            ├── main.tf
            ├── variables.tf
            └── outputs.tf
```

---

## Prerequisites

### For the microservice

| Tool | Purpose |
|------|---------|
| Docker | Build and run the container |
| kubectl | Deploy to Kubernetes |
| A running Kubernetes cluster (Docker Desktop, Minikube, Kind, or EKS) | Deployment target |

### For the Terraform infrastructure

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `~> 1.14` | Provision AWS resources |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Authenticate to AWS |

---

## Terraform — AWS VPC and EKS cluster

### What gets created

| Resource | Details |
|----------|---------|
| VPC | CIDR `10.0.0.0/24`, spread across 2 Availability Zones |
| Public subnets | 2 subnets (`10.0.0.0/26`, `10.0.0.64/26`) — tagged for external load balancers |
| Private subnets | 2 subnets (`10.0.0.128/26`, `10.0.0.192/26`) — tagged for internal load balancers |
| NAT Gateway | Single NAT gateway so private-subnet nodes can reach the internet |
| EKS cluster | Kubernetes 1.33, API endpoint publicly accessible (no CIDR restriction — acceptable for demos, but restrict `public_access_cidrs` in production) |
| Managed node group | `node_desired_size` × `m6a.large` on-demand nodes placed on private subnets only |
| EKS add-ons | `coredns`, `kube-proxy`, `vpc-cni` (latest versions) |

The EKS module used is [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) and the VPC module is [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest).

---

### Authenticating to AWS

**Never commit AWS credentials to the repository.** Use one of the following approaches:

#### Option 1 — AWS CLI named profile (recommended for local use)

```bash
# Configure a profile (interactive)
aws configure --profile my-profile

# Export the profile so Terraform picks it up
export AWS_PROFILE=my-profile
```

#### Option 2 — Environment variables

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-south-1"
```

#### Option 3 — IAM role / instance profile

If deploying from an EC2 instance, ECS task, GitHub Actions OIDC, or any other role-based environment, ensure the execution role has sufficient permissions and no static credentials are required.

#### Minimum IAM permissions

The IAM principal used by Terraform needs permissions to create and manage: VPC resources, EKS clusters, IAM roles and policies, EC2 Auto Scaling groups, and KMS keys (used internally by the EKS module).

A convenient starting point is the AWS managed policies `AmazonEKSClusterPolicy` and `AmazonEKSWorkerNodePolicy` combined with VPC and IAM write permissions. For production use, scope these down to the minimum required.

---

### Remote state backend

The project is configured to store Terraform state in an S3 bucket (`backend.tf`). State locking is handled natively by S3 (via conditional writes) as of Terraform 1.10 — no DynamoDB table is required.

Before running `terraform init` for the first time, either:

- Create the S3 bucket referenced in `backend.tf` in your AWS account, **or**
- Comment out the `backend "s3"` block to use local state instead.

```bash
# Create the state bucket (adjust name/region as needed)
aws s3api create-bucket \
  --bucket <your-bucket-name> \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
```

Update `backend.tf` with your bucket name and region before proceeding.

---

### Deploying the infrastructure

```bash
cd terraform

# Download providers and modules
terraform init

# Preview changes — no AWS resources are created yet
terraform plan

# Create the VPC and EKS cluster
terraform apply
```

`terraform plan` and `terraform apply` are the only commands needed. Type `yes` when prompted by `apply`.

#### Typical apply time

The full stack (VPC + NAT Gateway + EKS control plane + managed node group) typically takes **10–20 minutes** on a first apply, depending on AWS provisioning speed.

---

### Customising variables

All tuneable values are declared in `variables.tf` and can be overridden in `terraform.tfvars` or via `-var` flags.

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `ap-south-1` | AWS region to deploy into |
| `cluster_name` | `simple-eks` | EKS cluster name |
| `vpc_name` | `eks-vpc` | VPC name tag |
| `vpc_cidr` | `10.0.0.0/24` | VPC CIDR block |
| `azs` | `["ap-south-1a", "ap-south-1b"]` | Availability zones |
| `public_subnets` | `["10.0.0.0/26", "10.0.0.64/26"]` | Public subnet CIDRs |
| `private_subnets` | `["10.0.0.128/26", "10.0.0.192/26"]` | Private subnet CIDRs |
| `instance_type` | `m6a.large` | EC2 instance type for worker nodes |
| `node_desired_size` | `2` | Desired number of worker nodes |
| `node_min_size` | `2` | Minimum number of worker nodes |
| `node_max_size` | `2` | Maximum number of worker nodes |

To deploy in a different region, update `aws_region` and the `azs` list accordingly in `terraform.tfvars`.

---

### Cluster access — creator gets admin by default

The EKS module is configured with `enable_cluster_creator_admin_permissions = true` ([terraform/modules/eks/main.tf](terraform/modules/eks/main.tf)). This means the AWS IAM identity (user or role) that runs `terraform apply` is automatically granted `system:masters` access to the cluster, giving it full cluster-admin privileges with no additional RBAC setup required.

To grant access to other IAM identities, add them as EKS access entries in the EKS module configuration.

### Connecting kubectl to the cluster

After a successful `terraform apply`, authenticate your local `kubectl` by updating your kubeconfig. Run this as the **same IAM identity that ran `terraform apply`**:

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name simple-eks
```

If you use a named AWS profile, pass it explicitly:

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name simple-eks \
  --profile my-profile
```

Verify the connection and that nodes are running:

```bash
kubectl get nodes
```

---

### Destroying the infrastructure

```bash
cd terraform
terraform destroy
```

This removes all AWS resources created by Terraform. Confirm with `yes` when prompted.

---

## Microservice — Quick Start

```bash
kubectl apply -f k8s/microservice.yaml
kubectl port-forward svc/simple-time-service 8080:80
curl http://localhost:8080/
```

## Running locally

### Docker Compose (recommended)

```bash
docker compose up --build
```

The service is available at `http://localhost:8080`.

### Docker only

```bash
docker build -t simple-time-service ./sample-workload
docker run --rm -p 8080:8080 simple-time-service
```

### Verify

```bash
curl http://localhost:8080/
```

Expected response:

```json
{
  "timestamp": "2026-04-07T12:00:00.000000+00:00",
  "ip": "127.0.0.1"
}
```

---

## Deploying to Kubernetes

The manifest at `k8s/microservice.yaml` contains both a `Deployment` and a `ClusterIP` `Service`. No namespace is specified in the manifest, so resources are deployed into whichever namespace your current kubectl context is set to (typically `default`). A single command is all that is needed:

```bash
kubectl apply -f k8s/microservice.yaml
```

> The provided manifest is designed to work without creating a separate namespace. If you choose to deploy into a custom namespace, create it first and pass `-n <namespace>`.

### Verify the deployment

```bash
# Wait for pods to become ready
kubectl rollout status deployment/simple-time-service

# Check pods
kubectl get pods -l app=simple-time-service -w

# Check the service
kubectl get svc simple-time-service
```

## Deployment validation

The application is considered successfully deployed when:

- Pods reach `Running` state
- Readiness probe passes
- `curl http://localhost:8080/` returns valid JSON

### Test the endpoint

Because the Service type is `ClusterIP`, use `kubectl port-forward` to reach it from your local machine:

```bash
kubectl port-forward svc/simple-time-service 8080:80
```

Then in a second terminal:

```bash
curl http://localhost:8080/
```

---

## Docker image

The public image is published on DockerHub:

```
docker.io/nabeemdev/simple-time-service:v1
```

Pull it directly:

```bash
docker pull nabeemdev/simple-time-service:v1
```

### Building and pushing your own image

The image is built as a **multi-platform manifest** targeting both `linux/amd64` and `linux/arm64` using Docker Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <your-dockerhub-username>/simple-time-service:v1 \
  --push ./sample-workload
```

`--push` builds and pushes both platform variants to the registry in a single step — no separate `docker push` needed.

**Why multi-platform?**
- Runs natively on both x86 EKS nodes (`m6a.large`) and ARM-based Graviton nodes (`m7g`, `t4g`) — no emulation overhead
- Works out of the box on Apple Silicon (M-series) development machines
- Docker automatically pulls the correct variant for the host architecture

> Requires `docker buildx` (included in Docker Desktop). For CI, ensure the builder has `--platform linux/amd64,linux/arm64` support (e.g. QEMU or native multi-arch runners).

Then update the `image:` field in `k8s/microservice.yaml` before applying:

```yaml
image: docker.io/<your-dockerhub-username>/simple-time-service:v1
```

## Cleanup

To remove deployed resources:

```bash
kubectl delete -f k8s/microservice.yaml
```

---

## Container security

- Runs as a non-root system user (`uid 10001 / gid 10001`).
- `allowPrivilegeEscalation: false` and all Linux capabilities dropped.
- Read-only root filesystem enforced via `readOnlyRootFilesystem: true`.
- `securityContext.runAsNonRoot: true` enforced at the Pod level.
- Fixed UID/GID ensures predictable security context behavior in Kubernetes.
- Image built from minimal base image to reduce attack surface.

## Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Returns `timestamp` and caller `ip` |
| `/health` | GET | Liveness / readiness probe (`{"status": "ok"}`) |

## Technology

- **Runtime**: Python 3.12 (slim base image)
- **Framework**: FastAPI + Uvicorn
- **Container**: multi-stage-free single-stage build kept small via `python:3.12-slim` and pip cache clearing
- **ASGI server**: Uvicorn (production-grade async Python server)