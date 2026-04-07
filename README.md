# EKS GitOps Platform

This repository contains four components:

1. **SimpleTimeService** - a minimal Python microservice containerized with Docker and deployable to Kubernetes.
2. **Terraform infrastructure** - an AWS VPC and EKS cluster provisioned with Terraform.
3. **GitOps platform** - ArgoCD running on the EKS cluster, managing deployments via the App of Apps pattern.
4. **Monitoring** - Prometheus and Grafana deployed via ArgoCD using the `kube-prometheus-stack` Helm chart.

> **Naming note:** The application is called SimpleTimeService. Its source code lives under `sample-workload/`, the raw Kubernetes manifest is in `k8s/microservice.yaml`, and the Helm release name is `simple-time-service`. These names refer to the same service.

---

## Quick demo

```bash
# 1. Provision infrastructure
cd terraform && terraform init && terraform apply

# 2. Authenticate kubectl (use the same IAM identity that ran apply)
aws eks update-kubeconfig --region ap-south-1 --name simple-eks

# 3. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Bootstrap GitOps
kubectl apply -f gitops/bootstrap/root-app.yaml

# 5. Verify applications in ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080 - both simple-time-service and prometheus apps should appear

# 6. Verify the service
kubectl port-forward svc/simple-time-service 8080:80
curl http://127.0.0.1:8080/

# 7. Verify Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open http://localhost:3000
```

---

## Assumptions and scope

These choices are intentional for a demo environment:

- Single NAT gateway to reduce cost (use one per AZ in production).
- EKS API endpoint is publicly accessible - acceptable for demos; restrict `public_access_cidrs` in production.
- No ingress controller is included; services are accessed via `kubectl port-forward`.
- ArgoCD is installed manually once; everything else is GitOps-managed from that point.
- Prometheus Operator TLS and admission webhooks are disabled to simplify bootstrap reliability.
- `sample-workload/` folder name is kept as-is from the original task scaffolding.

---

## SimpleTimeService

A minimal Python microservice that returns the current UTC timestamp and the caller's IP address as JSON.
The service is containerized with Docker and runs as a non-root user. It can be deployed using a raw Kubernetes manifest (`k8s/microservice.yaml`) for a quick start, or via the Helm chart (`charts/simple-time-service/`) for a more configurable deployment aligned with production practices.

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
├── .github/
│   └── workflows/
│       └── sample-workload-image.yaml  # CI - build and push Docker image to Docker Hub
├── compose.yaml                   # Docker Compose for local development
├── gitops/
│   ├── bootstrap/
│   │   └── root-app.yaml          # ArgoCD root Application (App of Apps bootstrap)
│   ├── app/
│   │   └── simple-time-service.yaml  # ArgoCD ApplicationSet (multi-cluster Helm deploy)
│   └── prometheus/
│       └── prometheus.yaml         # ArgoCD ApplicationSet - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
├── k8s/
│   └── microservice.yaml          # Kubernetes Deployment + ClusterIP Service
├── charts/
│   └── simple-time-service/       # Helm chart for the microservice
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── pdb.yaml
│           └── NOTES.txt
├── sample-workload/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── .dockerignore
│   └── src/
│       └── app.py
└── terraform/                     # AWS infrastructure (VPC + EKS)
    ├── backend.tf                 # S3 remote state backend
    ├── main.tf                    # Root module - wires VPC and EKS modules
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

## Terraform - AWS VPC and EKS cluster

### What gets created

| Resource | Details |
|----------|---------|
| VPC | CIDR `10.0.0.0/24`, spread across 2 Availability Zones |
| Public subnets | 2 subnets (`10.0.0.0/26`, `10.0.0.64/26`) - tagged for external load balancers |
| Private subnets | 2 subnets (`10.0.0.128/26`, `10.0.0.192/26`) - tagged for internal load balancers |
| NAT Gateway | Single NAT gateway so private-subnet nodes can reach the internet |
| EKS cluster | Kubernetes 1.33, API endpoint publicly accessible (no CIDR restriction - acceptable for demos, but restrict `public_access_cidrs` in production) |
| Managed node group | `node_desired_size` × `m6a.large` on-demand nodes placed on private subnets only |
| EKS add-ons | `coredns`, `kube-proxy`, `vpc-cni` managed by the EKS module |

The EKS module used is [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) and the VPC module is [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest).

---

### Authenticating to AWS

**Never commit AWS credentials to the repository.** Use one of the following approaches:

#### Option 1 - AWS CLI named profile (recommended for local use)

```bash
# Configure a profile (interactive)
aws configure --profile my-profile

# Export the profile so Terraform picks it up
export AWS_PROFILE=my-profile
```

#### Option 2 - Environment variables

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-south-1"
```

#### Option 3 - IAM role / instance profile

If deploying from an EC2 instance, ECS task, GitHub Actions OIDC, or any other role-based environment, ensure the execution role has sufficient permissions and no static credentials are required.

#### Minimum IAM permissions

The IAM principal used by Terraform needs permissions to create and manage: VPC resources, EKS clusters, IAM roles and policies, EC2 Auto Scaling groups, and KMS keys (used internally by the EKS module).

A convenient starting point is the AWS managed policies `AmazonEKSClusterPolicy` and `AmazonEKSWorkerNodePolicy` combined with VPC and IAM write permissions. For production use, scope these down to the minimum required.

> **S3 backend note:** If you are using the S3 remote state backend (`backend.tf`), the Terraform principal also needs S3 permissions on the state bucket: `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket`. If native S3 state locking is enabled (use_lockfile = true), no DynamoDB table or DynamoDB permissions are required.

---

### Remote state backend

The project stores Terraform state remotely in an S3 bucket (backend.tf). Native S3 state locking is enabled with use_lockfile = true. DynamoDB-based locking for the S3 backend is deprecated.

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

# Preview changes - no AWS resources are created yet
terraform plan

# Create the VPC and EKS cluster
terraform apply
```

`terraform plan` previews changes; `terraform apply` provisions them. Confirm with `yes` when prompted.

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

### Cluster access - creator gets admin by default

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

## Helm Chart

The chart at `charts/simple-time-service/` is the recommended way to deploy the service to Kubernetes. It provides configurable replicas, resource limits, health probes, a PodDisruptionBudget, and a full set of security-context defaults - all tuneable through `values.yaml`.

> The raw manifest at `k8s/microservice.yaml` is a minimal alternative for quickly testing the service. The Helm chart is the configurable deployment used by ArgoCD in this platform.

### Prerequisites

| Tool | Purpose |
|------|---------|
| [Helm](https://helm.sh/docs/intro/install/) `>= 3` | Package manager for Kubernetes |
| A running Kubernetes cluster | Deployment target |

### Install

```bash
# From the repository root
helm install simple-time-service charts/simple-time-service
```

To install into a specific namespace:

```bash
kubectl create namespace simple-time-service
helm install simple-time-service charts/simple-time-service --namespace simple-time-service
```

### Upgrade

```bash
helm upgrade simple-time-service charts/simple-time-service
```

### Verify the deployment

```bash
kubectl rollout status deployment/simple-time-service
kubectl get pods -l app.kubernetes.io/name=simple-time-service
```

### Access the service

```bash
kubectl port-forward svc/simple-time-service 8080:80
curl http://127.0.0.1:8080/
```

### Uninstall

```bash
helm uninstall simple-time-service
```

### Chart values

All values can be overridden with `--set key=value` or a custom values file (`-f my-values.yaml`).

| Key | Default | Description |
|-----|---------|-------------|
| `fullnameOverride` | `simple-time-service` | Override the full resource name |
| `replicaCount` | `2` | Number of pod replicas |
| `image.repository` | `docker.io/nabeemdev/simple-time-service` | Container image repository |
| `image.tag` | `v1` | Image tag (`v1` = baseline, `latest` = metrics-enabled build) |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `service.type` | `ClusterIP` | Kubernetes Service type |
| `service.port` | `80` | Service port |
| `service.targetPort` | `8080` | Container port |
| `resources.requests.cpu` | `100m` | CPU request |
| `resources.requests.memory` | `128Mi` | Memory request |
| `resources.limits.cpu` | `250m` | CPU limit |
| `resources.limits.memory` | `256Mi` | Memory limit |
| `livenessProbe.path` | `/health` | Liveness probe HTTP path |
| `livenessProbe.initialDelaySeconds` | `5` | Liveness probe initial delay |
| `livenessProbe.periodSeconds` | `10` | Liveness probe interval |
| `readinessProbe.path` | `/health` | Readiness probe HTTP path |
| `readinessProbe.initialDelaySeconds` | `3` | Readiness probe initial delay |
| `readinessProbe.periodSeconds` | `5` | Readiness probe interval |
| `podSecurityContext.runAsNonRoot` | `true` | Enforce non-root at pod level |
| `podSecurityContext.runAsUser` | `10001` | UID for the container process |
| `podSecurityContext.runAsGroup` | `10001` | GID for the container process |
| `podSecurityContext.fsGroup` | `10001` | GID for volume mounts |
| `securityContext.allowPrivilegeEscalation` | `false` | Prevent privilege escalation |
| `securityContext.readOnlyRootFilesystem` | `true` | Read-only root filesystem |
| `securityContext.capabilities.drop` | `["ALL"]` | Drop all Linux capabilities |
| `serviceAccount.create` | `false` | Create a dedicated ServiceAccount |
| `serviceAccount.name` | `""` | ServiceAccount name (if not auto-generated) |
| `serviceAccount.annotations` | `{}` | Annotations for the ServiceAccount |
| `pdb.enabled` | `true` | Create a PodDisruptionBudget |
| `pdb.minAvailable` | `1` | Minimum pods available during disruptions |
| `serviceMonitor.enabled` | `false` | Create a Prometheus `ServiceMonitor` (requires Prometheus Operator) |
| `serviceMonitor.interval` | `30s` | Scrape interval |
| `serviceMonitor.path` | `/metrics` | Metrics endpoint path |
| `serviceMonitor.labels` | `{}` | Extra labels added to the `ServiceMonitor` (use to match Prometheus `serviceMonitorSelector`) |
| `podAnnotations` | `{}` | Extra pod annotations |
| `nodeSelector` | `{}` | Node selector constraints |
| `tolerations` | `[]` | Pod tolerations |
| `affinity` | `{}` | Pod affinity/anti-affinity rules |

### Example - deploy without metrics (v1)

```bash
helm install simple-time-service charts/simple-time-service \
  --set image.tag=v1
```

### Example - deploy with Prometheus metrics (latest)

Requires Prometheus Operator to be installed on the cluster.

```bash
helm install simple-time-service charts/simple-time-service \
  --set image.tag=latest \
  --set serviceMonitor.enabled=true
```

---

## GitOps - ArgoCD

The `gitops/` directory implements the **App of Apps** pattern: a single root Application bootstraps ArgoCD, which then discovers and reconciles all other applications declared in the repo.

```
gitops/
├── bootstrap/
│   └── root-app.yaml          # Root Application - watches gitops/ recursively
├── app/
│   └── simple-time-service.yaml  # ApplicationSet - deploys Helm chart to each registered cluster
└── prometheus/
    └── prometheus.yaml         # ApplicationSet - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
```

### How it works

1. **Root Application** (`gitops/bootstrap/root-app.yaml`) - deployed manually once. It is configured to watch the `gitops/` directory and create `Application` or `ApplicationSet` resources declared within it.
2. **ApplicationSet** (`gitops/app/simple-time-service.yaml`) - discovered automatically by the root app. Uses the cluster generator to deploy the `charts/simple-time-service` Helm chart to every cluster registered in ArgoCD.
3. **Prometheus ApplicationSet** (`gitops/prometheus/prometheus.yaml`) - discovered automatically by the root app. Deploys the `kube-prometheus-stack` Helm chart to every registered cluster, providing Prometheus, Grafana, and Alertmanager in the `monitoring` namespace.

After bootstrap, changes merged to `main` are automatically picked up by ArgoCD and reconciled according to the configured sync policy.

---

### Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` configured against the EKS cluster | Deploy and manage ArgoCD |
| `argocd` CLI (optional) | Interact with ArgoCD from the terminal |

---

### 1 - Install ArgoCD on the cluster

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all ArgoCD pods to become ready:

```bash
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd
```

---

### 2 - Retrieve the initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Note this password - it is required to log in to the UI and CLI.

---

### 3 - Deploy the root Application (bootstrap)

Apply the root app manifest once. This is the only manual deployment step:

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

ArgoCD immediately begins reconciling the `gitops/` directory. Within a few seconds it discovers `gitops/app/simple-time-service.yaml` and creates the `ApplicationSet`, which in turn provisions the `simple-time-service` application on every registered cluster.

---

### 4 - Access the ArgoCD UI

Port-forward the ArgoCD server to your local machine:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080) in your browser (the server uses a self-signed certificate). Log in with username `admin` and the password retrieved in step 2.

> The UI shows all applications and their sync status. Click **Sync** on any application to trigger a manual reconciliation.

---

### 5 - Sync the application

#### Via the UI

1. Open [https://localhost:8080](https://localhost:8080) and log in.
2. Click the **root-app** tile.
3. Click **Sync → Synchronize**. ArgoCD pulls the latest state from `main` and applies any diff.
4. Navigate back to the application list - the `simple-time-service` ApplicationSet and its child application should appear as **Synced / Healthy**.

#### Via the ArgoCD CLI

```bash
# Log in (keep port-forward running in another terminal)
argocd login localhost:8080 \
  --username admin \
  --password <password> \
  --insecure

# Sync the root app (triggers discovery of all child apps)
argocd app sync root-app

# Sync the service application directly
argocd app sync simple-time-service-in-cluster

# Watch live status
argocd app get simple-time-service-in-cluster
```

---

### Sync policy

The root Application is configured with **automated sync, pruning, and self-healing**:

```yaml
syncPolicy:
  automated:
    prune: true      # delete resources removed from Git
    selfHeal: true   # revert any manual changes made directly in the cluster
```

Any `git push` to `main` that modifies files under `gitops/` or `charts/` will be automatically detected and applied within the default ArgoCD polling interval (3 minutes). Manual syncs via the UI or CLI take effect immediately.

---

## Monitoring - Prometheus, Grafana, and Alertmanager

The `gitops/prometheus/prometheus.yaml` ApplicationSet deploys the [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm chart to every cluster registered in ArgoCD.

### What gets deployed

| Component | Details |
|-----------|---------|
| Prometheus | Metrics collection with a 7-day retention window |
| Grafana | Dashboards UI, auto-provisioned with the Prometheus data source |
| Alertmanager | Alert routing and grouping |
| Prometheus Operator | Manages `PrometheusRule` and `ServiceMonitor` CRDs |

All components are installed into the `monitoring` namespace, which ArgoCD creates automatically via `CreateNamespace=true`.

### Configuration highlights

```yaml
grafana:
  enabled: true

alertmanager:
  enabled: true

prometheus:
  prometheusSpec:
    retention: 7d

prometheusOperator:
  tls:
    enabled: false
  admissionWebhooks:
    enabled: false
```

TLS and admission webhooks on the operator are disabled to simplify initial cluster setup. Enable them in production environments for additional security.

### Access Grafana

Once ArgoCD has synced the application, port-forward Grafana to your local machine:

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open [http://localhost:3000](http://localhost:3000) in your browser. By default, the chart creates Grafana with username `admin`; the password is commonly `prom-operator` unless overridden via `grafana.adminPassword`. If login fails, inspect the generated secret in the `monitoring` namespace:

```bash
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

### Access Prometheus

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Open [http://localhost:9090](http://localhost:9090) to query metrics directly.

---

## Microservice - Quick Start (raw manifests)

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

## CI - GitHub Actions

The workflow at `.github/workflows/sample-workload-image.yaml` automatically builds and pushes the Docker image to Docker Hub.

### Triggers

| Event | Condition | Behaviour |
|-------|-----------|-----------|
| Push to `main` | Files under `sample-workload/**` or the workflow file changed | Build + push |
| Pull request | Same path filter | Build only (no push) |
| `workflow_dispatch` | Manual trigger from the Actions UI | Build + push |

### Tagging strategy

| Tag | When applied | Notes |
|-----|-------------|-------|
| Short commit SHA (e.g. `a1b2c3d`) | Every build | Immutable per-commit reference |
| `latest` | Push to `main` only | Tracks the current `main` - includes Prometheus `/metrics` endpoint |
| `v1` | Pinned manually | Baseline version without metrics |

### Required secrets

Before the workflow can push to Docker Hub, add these two secrets to the repository (**Settings → Secrets and variables → Actions → New repository secret**):

| Secret | Value |
|--------|-------|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | A Docker Hub access token (not your password) |

Generate a token at **Docker Hub → Account Settings → Personal access tokens**.

---

## Docker image

The image is published on Docker Hub under two distinct tags:

| Tag | Metrics endpoint | Use when |
|-----|-----------------|----------|
| `v1` | No | You don't need Prometheus metrics |
| `latest` | Yes (`/metrics`) | You want Prometheus scraping via ServiceMonitor |

> **`v1`** is a pinned baseline - the original service with no instrumentation.
> **`latest`** tracks `main` and includes the Prometheus `/metrics` endpoint exposed by `prometheus-fastapi-instrumentator`. Use this tag when deploying with the Helm chart and `serviceMonitor.enabled=true`.

```bash
# No metrics (baseline)
docker pull nabeemdev/simple-time-service:v1

# With /metrics endpoint (convenient for demos; in production prefer an immutable version tag)
docker pull nabeemdev/simple-time-service:latest
```

### Building and pushing your own image

The image is built as a **multi-platform manifest** targeting both `linux/amd64` and `linux/arm64` using Docker Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <your-dockerhub-username>/simple-time-service:latest \
  --push ./sample-workload
```

`--push` builds and pushes both platform variants to the registry in a single step - no separate `docker push` needed.

**Why multi-platform?**
- Runs natively on both x86 EKS nodes (`m6a.large`) and ARM-based Graviton nodes (`m7g`, `t4g`) - no emulation overhead
- Works out of the box on Apple Silicon (M-series) development machines
- Docker automatically pulls the correct variant for the host architecture

> Requires `docker buildx` (included in Docker Desktop). The CI workflow handles this automatically via QEMU - see the [GitHub Actions](#ci--github-actions) section.

Then update the `image:` field in `k8s/microservice.yaml` before applying:

```yaml
image: docker.io/<your-dockerhub-username>/simple-time-service:latest
```

## Cleanup

### 1 - Remove ArgoCD-managed applications

```bash
# Delete the root app - ArgoCD will prune all child apps and their resources
kubectl delete -f gitops/bootstrap/root-app.yaml
```

Wait for ArgoCD to finish pruning (the `simple-time-service` and `prometheus` namespaces and their resources will be removed automatically if `prune: true` is set in the sync policy).

### 2 - Uninstall ArgoCD

```bash
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

### 3 - Remove the Helm release (if deployed outside ArgoCD)

```bash
helm uninstall simple-time-service
# If installed in a custom namespace:
helm uninstall simple-time-service --namespace simple-time-service
kubectl delete namespace simple-time-service
```

### 4 - Remove raw manifest resources (if applied directly)

```bash
kubectl delete -f k8s/microservice.yaml
```

### 5 - Destroy the Terraform infrastructure

```bash
cd terraform
terraform destroy
```

This removes all AWS resources (VPC, EKS cluster, node group, NAT Gateway, IAM roles). Confirm with `yes` when prompted.

> **S3 state bucket:** `terraform destroy` does **not** delete the S3 bucket used for remote state. Remove it manually after the destroy if it is no longer needed:
> ```bash
> aws s3 rb s3://<your-bucket-name> --force
> ```

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
| `/metrics` | GET | Prometheus metrics (available on `latest` tag only — see table below) |

### Prometheus metrics exposed

Metrics are emitted by [`prometheus-fastapi-instrumentator`](https://github.com/trallnag/prometheus-fastapi-instrumentator) and the standard Python `prometheus_client` collectors.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `http_requests_total` | Counter | `method`, `handler`, `status` | Total HTTP requests completed |
| `http_request_duration_seconds` | Histogram | `method`, `handler`, `status` | Request latency distribution (use for p50/p95/p99) |
| `http_request_duration_highr_seconds` | Histogram | — | High-resolution latency histogram (no label cardinality) |
| `http_request_size_bytes` | Histogram | `method`, `handler` | Incoming request body size |
| `http_response_size_bytes` | Histogram | `method`, `handler` | Outgoing response body size |
| `http_requests_inprogress` | Gauge | `method`, `handler` | Currently in-flight requests |
| `process_*` | Various | — | Python process metrics (CPU, memory, file descriptors) |
| `python_*` | Various | — | Python runtime metrics (GC, info) |

## Technology

- **Runtime**: Python 3.12 (slim base image)
- **Framework**: FastAPI + Uvicorn
- **Container**: single-stage build based on python:3.12-slim, kept small by clearing pip cache.
- **ASGI server**: Uvicorn (production-grade async Python server)

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `kubectl get nodes` returns `Unauthorized` | Run `aws eks update-kubeconfig` using the same IAM identity that ran `terraform apply`, or add that identity as an EKS access entry. |
| ArgoCD apps not appearing after bootstrap | Manually sync the root app: `argocd app sync root-app` or click **Sync** on the root-app tile in the UI. |
| Service not reachable from localhost | The Service type is `ClusterIP`. Use `kubectl port-forward svc/simple-time-service 8080:80` to reach it locally. |