# Terraform - AWS VPC and EKS Cluster

This directory provisions the AWS infrastructure: a VPC and an EKS cluster. The `app-bootstrap/` subdirectory is an alternative module that provisions the full stack (infrastructure + app) in a single apply. Lifecycle scripts (bootstrap, upgrade, cleanup) live in `scripts/`.

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `~> 1.14` | Provision AWS resources |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Authenticate to AWS |

---

## What gets created

| Resource | Details |
|----------|---------|
| VPC | CIDR `10.0.0.0/24`, spread across 2 Availability Zones |
| Public subnets | 2 subnets (`10.0.0.0/26`, `10.0.0.64/26`) - tagged for external load balancers |
| Private subnets | 2 subnets (`10.0.0.128/26`, `10.0.0.192/26`) - tagged for internal load balancers |
| NAT Gateway | Single NAT gateway so private-subnet nodes can reach the internet |
| EKS cluster | Kubernetes 1.34, API endpoint publicly accessible (restrict `public_access_cidrs` in production) |
| Managed node group | `node_desired_size` × `m6a.large` on-demand nodes on private subnets, labeled `app=core`, tainted `app=core:NoSchedule` |
| Node security group | NLB NodePort rule optional (`enable_nlb_nodeport_rule`); Karpenter discovery tag when `enable_karpenter_discovery_tags=true` |
| EKS add-ons | `coredns`, `kube-proxy`, `vpc-cni`, `eks-pod-identity-agent` managed by the EKS module |
| Karpenter | IAM controller role + EKS Pod Identity association + node IAM role + instance profile + SQS interruption queue |
| IRSA roles | Cluster Autoscaler, AWS Load Balancer Controller, ExternalDNS, External Secrets Operator, EBS CSI Driver controller, Thanos Prometheus sidecar, Thanos Compactor + StoreGateway, Loki |
| Thanos S3 bucket | `<cluster-name>-thanos-metrics-<account-id>-<region>` - versioned, AES256-encrypted, public access blocked |
| Loki S3 bucket | `<cluster-name>-loki-logs-<account-id>-<region>` - versioned, AES256-encrypted, public access blocked |
| Secrets Manager | `argocd-admin`, `grafana-admin`, `alertmanager-webhook` secrets provisioned by Terraform |

Modules used: [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest), [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest), and [`terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts`](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest).

---

## Authenticating to AWS

**Never commit AWS credentials to the repository.** Use one of the following approaches:

### Option 1 - AWS CLI named profile (recommended for local use)

```bash
aws configure --profile my-profile
export AWS_PROFILE=my-profile
```

### Option 2 - Environment variables

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-south-1"
```

### Option 3 - IAM role / instance profile

If deploying from an EC2 instance, ECS task, GitHub Actions OIDC, or any other role-based environment, ensure the execution role has sufficient permissions and no static credentials are required.

### Minimum IAM permissions

The IAM principal needs permissions to create and manage: VPC resources, EKS clusters, IAM roles and policies, EC2 Auto Scaling groups, and KMS keys.

A convenient starting point is `AmazonEKSClusterPolicy` and `AmazonEKSWorkerNodePolicy` combined with VPC and IAM write permissions. Scope these down for production.

> **S3 backend note:** If using the S3 remote state backend, the Terraform principal also needs `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` on the state bucket.

---

## Remote state backend

State is stored remotely in an S3 bucket (`backend.tf`). Native S3 state locking is enabled with `use_lockfile = true`. DynamoDB-based locking is deprecated.

Before running `terraform init` for the first time, either:
- Create the S3 bucket referenced in `backend.tf`, **or**
- Comment out the `backend "s3"` block to use local state.

```bash
aws s3api create-bucket \
  --bucket <your-bucket-name> \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
```

Update `backend.tf` with your bucket name and region before proceeding.

---

## Deploying the infrastructure

```bash
cd terraform

terraform init
terraform plan
terraform apply
```

Confirm with `yes` when prompted. The full stack (VPC + NAT Gateway + EKS control plane + managed node group) typically takes **10–20 minutes** on first apply.

---

## Customising variables

All tuneable values are declared in `variables.tf` and can be overridden in `terraform.tfvars` or via `-var` flags.

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `ap-south-1` | AWS region to deploy into |
| `cluster_name` | `simple-eks` | EKS cluster name |
| `vpc_name` | (required) | VPC name tag |
| `vpc_cidr` | `10.0.0.0/24` | VPC CIDR block |
| `azs` | `["ap-south-1a", "ap-south-1b"]` | Availability zones |
| `public_subnets` | `["10.0.0.0/26", "10.0.0.64/26"]` | Public subnet CIDRs |
| `private_subnets` | `["10.0.0.128/26", "10.0.0.192/26"]` | Private subnet CIDRs |
| `instance_type` | `m6a.large` | EC2 instance type for the core managed node group |
| `node_desired_size` | `2` | Desired number of core worker nodes |
| `node_min_size` | `2` | Minimum number of core worker nodes |
| `node_max_size` | `2` | Maximum number of core worker nodes (`terraform.tfvars` sets `4`) |
| `environment` | `prod` | Environment label used in ArgoCD cluster metadata |
| `domain_name` | (required) | Route53 hosted zone domain for ExternalDNS |
| `enable_nlb_nodeport_rule` | `false` | Add NodePort security group rule for NLB (app-bootstrap only) |
| `add_cluster_autoscaler_tags` | `false` | Add Cluster Autoscaler discovery tags to the node group |
| `enable_karpenter_discovery_tags` | `false` | Add Karpenter discovery tags to private subnets and node SG |
| `argocd_admin_password_hash` | (required) | Bcrypt hash of ArgoCD admin password (set by `bootstrap.sh`) |
| `argocd_admin_password_plaintext` | `null` | Plaintext password stored in Secrets Manager for recovery |
| `grafana_admin_user` | `admin` | Grafana admin username |
| `grafana_admin_password` | (required) | Grafana admin password (set by `bootstrap.sh`) |
| `alertmanager_slack_webhook_url` | (required) | Slack incoming webhook URL for Alertmanager |

To deploy in a different region, update `aws_region` and the `azs` list in `terraform.tfvars`.

---

## Cluster access

The EKS module is configured with `enable_cluster_creator_admin_permissions = true`. This grants the IAM identity that runs `terraform apply` cluster-admin access - no additional RBAC configuration is required.

### Connecting kubectl

After a successful apply, authenticate kubectl using the **same IAM identity that ran `terraform apply`**:

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name simple-eks
```

With a named profile:

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name simple-eks \
  --profile my-profile
```

Verify the connection:

```bash
kubectl get nodes
```

---

## Destroying the infrastructure

```bash
cd terraform
terraform destroy
```

Confirm with `yes`. This removes all AWS resources created by Terraform.

> **S3 state bucket:** `terraform destroy` does **not** delete the S3 bucket. Remove it manually if no longer needed:
> ```bash
> aws s3 rb s3://<your-bucket-name> --force
> ```

---

## Lifecycle scripts

All scripts live in `terraform/scripts/` and require `terraform`, `aws`, `kubectl`, `openssl`, `git`, and `htpasswd` (`brew install httpd` on macOS).

### bootstrap.sh - full cluster bring-up

`terraform/scripts/bootstrap.sh` is the recommended end-to-end bootstrap path. It:

1. Runs `terraform apply` in `terraform/` to provision infrastructure and secrets
2. Runs `aws eks update-kubeconfig`
3. Installs ArgoCD via Helm (`argo-cd` chart v9.4.17)
4. Creates the ArgoCD cluster secret with cluster metadata annotations used by ApplicationSet generators
5. Applies `gitops/bootstrap/root-app.yaml` to start full GitOps reconciliation

```bash
# Required - Slack webhook URL
export TF_VAR_alertmanager_slack_webhook_url="https://hooks.slack.com/..."

# Optional - auto-generated if not set
# export ARGOCD_ADMIN_PASSWORD="<password>"
# export TF_VAR_grafana_admin_password="<password>"
# export TF_VAR_argocd_admin_password_hash="<bcrypt-hash>"  # skip htpasswd generation

bash terraform/scripts/bootstrap.sh
```

### upgrade.sh - re-apply Terraform on a running cluster

Use `upgrade.sh` when you need to apply Terraform changes or rotate secrets without reinstalling ArgoCD. It re-runs Terraform, refreshes the ArgoCD cluster secret with the latest outputs (including the Thanos bucket name), and force-annotates all three ExternalSecrets to trigger an immediate re-sync.

```bash
export TF_VAR_alertmanager_slack_webhook_url="https://hooks.slack.com/..."
bash terraform/scripts/upgrade.sh
```

### cleanup.sh - tear everything down

`terraform/scripts/cleanup.sh` removes all ArgoCD apps then destroys the full infrastructure.

---

## App-bootstrap - one-step infrastructure and app deployment

`terraform/app-bootstrap/` is an alternative Terraform root module that provisions the full stack - VPC, EKS cluster, Kubernetes namespace, and the SimpleTimeService Helm release - in a single `terraform apply`. Use it for a quick demo without ArgoCD.

> **Portability note:** The module uses `local-exec` provisioners that shell out to `aws`, `kubectl`, `curl`, and `nslookup`. It works well on a prepared local machine, but it is not purely provider-driven Terraform.

### What the app-bootstrap module does differently

| Step | Root `terraform/` | `terraform/app-bootstrap/` |
|------|-------------------|---------------------------|
| VPC + EKS | Yes | Yes (same shared modules) |
| Update kubeconfig | No | Yes (`null_resource` runs `aws eks update-kubeconfig`) |
| Create namespace | No | Yes (`kubernetes_namespace`) |
| Deploy SimpleTimeService | No | Yes (Helm release with NLB service) |
| Remote state key | `terraform.tfstate` | `bootstrap/terraform.tfstate` |

### Deploying with app-bootstrap

```bash
cd terraform/app-bootstrap

terraform init
terraform plan
terraform apply
```

After a successful apply:

```
Outputs:

application_url = "http://<nlb-hostname>"
application_nlb_hostname = "<nlb-hostname>"
cluster_name = "simple-eks"
vpc_id = "vpc-..."
```

Terraform polls the EKS API server every 15 seconds (up to 5 minutes) before proceeding, then waits for the NLB hostname (up to 10 minutes), then polls `GET /health` every 15 seconds (up to 10 minutes) until HTTP 200 is returned. The apply only completes once the endpoint is confirmed healthy.

### NLB NodePort security group rule

When `enable_nlb_nodeport_rule = true`, the EKS module adds this rule to the node security group:

```hcl
node_security_group_additional_rules = {
  ingress_nlb_nodeports = {
    description = "Allow NLB to reach NodePorts (NLB preserves source IP)"
    protocol    = "tcp"
    from_port   = 30000
    to_port     = 32767
    type        = "ingress"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

An NLB operates at Layer 4 and preserves the original client IP. Because of this, the source address is unpredictable and the security group must allow `0.0.0.0/0` on the NodePort range. Without this rule the NLB health checks and forwarded traffic are silently dropped.

> In production, restrict this range to the NLB's subnet CIDRs if your NLB is internal.

### App-bootstrap remote state

The app-bootstrap module uses the same S3 bucket as the root module but stores state under a different key (`bootstrap/terraform.tfstate`). Both modules can coexist without interfering.

### Destroying the app-bootstrap stack

```bash
cd terraform/app-bootstrap
terraform destroy
```

This removes all resources provisioned by the app-bootstrap module, including the Helm release, namespace, EKS cluster, and VPC.
