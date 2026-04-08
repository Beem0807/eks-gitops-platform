# EKS GitOps Platform

This repository contains six platform components plus a shared utility chart:

1. **SimpleTimeService** - a minimal Python microservice containerized with Docker and deployable to Kubernetes.
2. **Terraform infrastructure** - an AWS VPC and EKS cluster provisioned with Terraform.
3. **GitOps platform** - ArgoCD running on the EKS cluster, managing deployments via the App of Apps pattern.
4. **Monitoring and Alerting** - Prometheus, Grafana, and Alertmanager deployed via ArgoCD using the `kube-prometheus-stack` Helm chart, with a pre-built Grafana dashboard auto-provisioned via `charts/raw`, and PrometheusRule-based alerts routed to Slack via an `AlertmanagerConfig` CRD.
5. **Autoscaling** - `metrics-server` deployed via ArgoCD enabling HPA-based horizontal pod autoscaling for SimpleTimeService.
6. **Log Aggregation** - Loki deployed in single-binary mode (demo topology, ephemeral storage), Fluent Bit running as a DaemonSet to collect and forward container logs, and a Grafana Loki datasource auto-provisioned via `charts/raw` so logs are queryable in Grafana immediately after bootstrap.

**Utility:** `charts/raw` - a reusable generic Helm chart for deploying arbitrary Kubernetes resources through the same ApplicationSet pattern used by the platform components above.

> **Naming note:** The application is called SimpleTimeService. Its source code lives under `app/`, the raw Kubernetes manifest is in `k8s/microservice.yaml`, and the Helm release name is `simple-time-service`. These names refer to the same service.

---

## Quick demo

```bash
# 1. Provision infrastructure (infrastructure + app in one step)
cd terraform/bootstrap && terraform init && terraform apply
# OR: cd terraform && terraform init && terraform apply  (infrastructure only)

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
# Open https://localhost:8080 - apps for the service, monitoring, metrics-server,
# Grafana dashboard, and alerting should appear (first reconciliation takes up to 3 minutes)
# If apps are missing: argocd app sync root-app
# Note: the alertmanager-slack app will show as degraded until the Slack secret is applied (see Alerting section)

# 6. Verify the service
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
curl http://127.0.0.1:8080/

# 7. Verify Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open http://localhost:3000
```

---

## Validation checklist

A reviewer can verify the full stack is working in under a minute using these checkpoints:

| # | What to check | Command |
|---|---------------|---------|
| 1 | Terraform provisioned the cluster | `kubectl get nodes` - all nodes `Ready` |
| 2 | ArgoCD root app synced | Check UI at `https://localhost:8080` or run `argocd app get root-app` - `Synced / Healthy` |
| 3 | Service is responding | `curl http://127.0.0.1:8080/` - returns `timestamp` + `ip` JSON |
| 4 | Prometheus is scraping the service | After port-forwarding Prometheus (`kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090`), open `http://localhost:9090/targets` - `simple-time-service` target `UP` |
| 5 | Grafana dashboard is populated | Open `http://localhost:3000` - SimpleTimeService dashboard shows live data |
| 6 | HPA scales under load | `kubectl get hpa -n simple-time-service -w` while running `python3 scripts/load_test.py` |
| 7 | Slack alert is delivered | Fire test alert via curl (see [Testing the Slack receiver](#testing-the-slack-receiver)) - message appears in `#alerts-test` |
| 8 | Loki API reachable | `kubectl port-forward svc/loki-gateway -n logging 3100:80` → `curl 'http://localhost:3100/loki/api/v1/labels'` returns a non-empty response |
| 9 | Logs queryable in Grafana | Open `http://localhost:3000` → Explore → select **Loki** datasource → run `{namespace="simple-time-service"}` |

---

## Assumptions and scope

These choices are intentional for a demo environment:

- Single NAT gateway to reduce cost (use one per AZ in production).
- EKS API endpoint is publicly accessible - acceptable for demos; restrict `public_access_cidrs` in production.
- No ingress controller is included; services are accessed via `kubectl port-forward`.
- ArgoCD is installed manually once; everything else is GitOps-managed from that point.
- Prometheus Operator TLS and admission webhooks are disabled to simplify bootstrap reliability.

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
│       └── app-image.yaml             # CI - build and push Docker image to Docker Hub
├── compose.yaml                   # Docker Compose for local development
├── gitops/
│   ├── bootstrap/
│   │   └── root-app.yaml                    # ArgoCD root Application (App of Apps bootstrap)
│   ├── app/
│   │   └── simple-time-service.yaml         # ArgoCD ApplicationSet (multi-cluster Helm deploy)
│   ├── prometheus/
│   │   └── prometheus.yaml                  # ArgoCD ApplicationSet - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
│   ├── metrics-server/
│   │   └── metrics-server.yaml              # ArgoCD ApplicationSet - metrics-server (required for HPA)
│   ├── grafana/
│   │   └── simple-time-service-dashboard.yaml  # ArgoCD ApplicationSet - Grafana dashboard via charts/raw
│   ├── alerts/
│   │   ├── simple-time-service-alerts.yaml  # ArgoCD ApplicationSet - PrometheusRule (alert expressions)
│   │   └── alertmanager-slack.yaml          # ArgoCD ApplicationSet - AlertmanagerConfig (Slack routing)
│   ├── loki/
│   │   ├── loki.yaml                        # ArgoCD ApplicationSet - Loki (single-binary log store)
│   │   └── grafana-loki-datasource.yaml     # ArgoCD ApplicationSet - Grafana Loki datasource ConfigMap via charts/raw
│   └── fluent-bit/
│       └── fluent-bit.yaml                  # ArgoCD ApplicationSet - Fluent Bit DaemonSet (log collector → Loki)
├── k8s/
│   └── microservice.yaml          # Kubernetes Deployment + ClusterIP Service
├── charts/
│   ├── raw/                       # Generic Helm chart - deploy any Kubernetes resource via .Values.resources list
│   │   ├── Chart.yaml
│   │   └── templates/
│   │       └── resources.yaml
│   └── simple-time-service/       # Helm chart for the microservice
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── pdb.yaml
│           ├── hpa.yaml
│           ├── networkpolicy.yaml
│           └── NOTES.txt
├── app/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── .dockerignore
│   └── src/
│       └── app.py
├── docs/
│   └── images/
│       ├── ArgoCD UI.png              # ArgoCD applications view
│       ├── Grafana Dashboard.png      # SimpleTimeService Grafana dashboard
│       ├── Alert.png                 # Slack alert notification
│       └── logs.png                  # Loki logs in Grafana Explore
├── secrets/
│   └── alertmanager-config.example.yaml  # Template for Slack webhook secret (gitignored when filled in)
├── scripts/
│   ├── load_test.py               # Python stdlib load generator (HPA / observability validation)
│   └── k6-staged.js               # k6 staged ramping-arrival-rate load test
└── terraform/                     # AWS infrastructure (VPC + EKS)
    ├── backend.tf                 # S3 remote state backend
    ├── main.tf                    # Root module - wires VPC and EKS modules
    ├── variables.tf               # Input variable declarations
    ├── terraform.tfvars           # Default variable values
    ├── outputs.tf                 # Root-level outputs
    ├── providers.tf               # AWS provider configuration
    ├── versions.tf                # Terraform and provider version constraints
    ├── bootstrap/                 # Bootstrap module - infrastructure + app in one apply
    │   ├── backend.tf             # S3 remote state (key: bootstrap/terraform.tfstate)
    │   ├── main.tf                # VPC + EKS + kubeconfig + namespace + Helm release
    │   ├── variables.tf
    │   ├── terraform.tfvars
    │   ├── outputs.tf
    │   ├── providers.tf
    │   └── versions.tf
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
| Node security group | Additional inbound rule: TCP 30000–32767 from `0.0.0.0/0` so the NLB can reach NodePorts (NLB preserves the source IP, so the security group must allow the full public range) |
| EKS add-ons | `coredns`, `kube-proxy`, `vpc-cni` (Network Policy controller **disabled by default** — see [Network Policy](#network-policy)) managed by the EKS module |

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

> **S3 backend note:** If you are using the S3 remote state backend (`backend.tf`), the Terraform principal also needs S3 permissions on the state bucket: `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket`. If native S3 state locking is enabled (`use_lockfile = true`), no DynamoDB table or DynamoDB permissions are required.

---

### Remote state backend

The project stores Terraform state remotely in an S3 bucket (`backend.tf`). Native S3 state locking is enabled with `use_lockfile = true`. DynamoDB-based locking for the S3 backend is deprecated.

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

The EKS module is configured with `enable_cluster_creator_admin_permissions = true` ([terraform/modules/eks/main.tf](terraform/modules/eks/main.tf)). This grants the IAM identity that runs `terraform apply` cluster-admin style access via the module's creator-admin setting, so no additional access entry or RBAC configuration is required to use `kubectl` immediately after provisioning.

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

## Bootstrap - one-step infrastructure and app deployment

`terraform/bootstrap/` is an alternative Terraform root module that provisions the full stack — VPC, EKS cluster, Kubernetes namespace, and the SimpleTimeService Helm release — in a single `terraform apply`. Use it when you want to stand up the complete environment without separately running Terraform and then ArgoCD.

### What the bootstrap module does differently from `terraform/`

| Step | Root `terraform/` | `terraform/bootstrap/` |
|------|-------------------|------------------------|
| VPC + EKS | Yes | Yes (same shared modules) |
| Update kubeconfig | No | Yes (`null_resource` runs `aws eks update-kubeconfig`) |
| Create namespace | No | Yes (`kubernetes_namespace`) |
| Deploy SimpleTimeService | No | Yes (Helm release with NLB service) |
| Remote state key | `terraform.tfstate` | `bootstrap/terraform.tfstate` |

The Helm release uses the same `charts/simple-time-service` chart and deploys it with a `LoadBalancer` service of type NLB (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`), so the service is publicly reachable immediately after apply without any port-forwarding.

### Deploying with the bootstrap module

```bash
cd terraform/bootstrap

# Download providers and modules
terraform init

# Preview changes
terraform plan

# Provision VPC + EKS + namespace + Helm release in one step
terraform apply
```

After a successful apply, the public NLB hostname is printed as `application_url`:

```
Outputs:

application_url = "http://<nlb-hostname>"
application_load_balancer_hostname = "<nlb-hostname>"
cluster_name = "simple-eks"
vpc_id = "vpc-..."
```

It typically takes **2–3 minutes** after the NLB hostname appears before DNS propagates and the endpoint becomes reachable.

### Node security group - NLB NodePort access

The EKS module (`terraform/modules/eks/main.tf`) adds the following rule to the node security group:

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

An NLB operates at Layer 4 and does **not** replace the source IP with its own — traffic arriving at nodes carries the original client IP. Because of this, the source address is unpredictable and the security group must allow the full public range (`0.0.0.0/0`) on the NodePort range. Without this rule the NLB health checks and forwarded traffic are silently dropped by the node security group, making the service unreachable even though the NLB itself shows healthy targets.

> In production, restrict this range to the NLB's subnet CIDRs if your NLB is internal, or retain `0.0.0.0/0` only for internet-facing NLBs where client IPs are genuinely arbitrary.

### Bootstrap remote state

The bootstrap module uses the same S3 bucket as the root module but stores state under a different key (`bootstrap/terraform.tfstate`). Both modules can coexist in the same bucket without interfering with each other.

### Destroying the bootstrap stack

```bash
cd terraform/bootstrap
terraform destroy
```

This removes all resources provisioned by the bootstrap module, including the Helm release, namespace, EKS cluster, and VPC.

---

## Helm Chart

The chart at `charts/simple-time-service/` is the recommended way to deploy the service to Kubernetes. It provides configurable replicas, resource limits, health probes, a PodDisruptionBudget, HPA-based autoscaling, and a full set of security-context defaults - all tuneable through `values.yaml`.

> The raw manifest at `k8s/microservice.yaml` is a minimal alternative for quickly testing the service. The Helm chart is the configurable deployment used by ArgoCD in this platform.

### Prerequisites

| Tool | Purpose |
|------|---------|
| [Helm](https://helm.sh/docs/intro/install/) `>= 3` | Package manager for Kubernetes |
| A running Kubernetes cluster | Deployment target |

### Install

```bash
# Into the default namespace
helm install simple-time-service charts/simple-time-service

# Into a custom namespace (e.g. simple-time-service)
kubectl create namespace simple-time-service
helm install simple-time-service charts/simple-time-service --namespace simple-time-service
```

### Upgrade

```bash
helm upgrade simple-time-service charts/simple-time-service
```

### Verify the deployment

```bash
# Default namespace
kubectl rollout status deployment/simple-time-service
kubectl get pods -l app.kubernetes.io/name=simple-time-service

# Custom namespace
kubectl rollout status deployment/simple-time-service -n simple-time-service
kubectl get pods -n simple-time-service -l app.kubernetes.io/name=simple-time-service
```

### Access the service

```bash
# Default namespace
kubectl port-forward svc/simple-time-service 8080:80

# Custom namespace
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80

curl http://127.0.0.1:8080/
```

### Uninstall

```bash
# Default namespace
helm uninstall simple-time-service

# Custom namespace
helm uninstall simple-time-service --namespace simple-time-service
kubectl delete namespace simple-time-service
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
| `networkPolicy.enabled` | `false` | Create a NetworkPolicy restricting ingress and egress |
| `hpa.enabled` | `false` | Create a HorizontalPodAutoscaler (requires `metrics-server`) |
| `hpa.minReplicas` | `2` | Minimum number of replicas |
| `hpa.maxReplicas` | `10` | Maximum number of replicas |
| `hpa.targetCPUAverageUtilization` | `70` | Target average CPU utilization across pods |
| `hpa.scaleDown.stabilizationWindowSeconds` | `300` | Seconds to wait after load drops before scaling down |
| `hpa.scaleDown.pods` | `1` | Max pods to remove per scale-down period |
| `hpa.scaleDown.periodSeconds` | `60` | Scale-down policy period length in seconds |
| `hpa.scaleUp.stabilizationWindowSeconds` | `0` | Seconds to wait before scaling up (0 = immediate) |
| `hpa.scaleUp.pods` | `2` | Max pods to add per scale-up period |
| `hpa.scaleUp.periodSeconds` | `30` | Scale-up policy period length in seconds |
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

## Generic Helm chart (`charts/raw`)

The `charts/raw` chart is a minimal, reusable chart that renders any list of Kubernetes resources passed in via `values.yaml`. It is modelled after the [Helm incubator `raw` chart](https://github.com/helm/charts/tree/master/incubator/raw) and exists so that every resource in the platform - including plain ConfigMaps - can be deployed through the same ApplicationSet pattern without needing a separate raw manifest in `gitops/`.

### How it works

`charts/raw/templates/resources.yaml` loops over `.Values.resources` and renders each entry as a YAML document:

```yaml
{{- range .Values.resources }}
---
{{ toYaml . }}
{{- end }}
```

Anything that is valid Kubernetes YAML can be placed in the `resources:` list.

### Usage

Reference `charts/raw` as the Helm source in any ApplicationSet:

```yaml
source:
  repoURL: https://github.com/Beem0807/eks-gitops-platform.git
  targetRevision: main
  path: charts/raw
  helm:
    releaseName: my-release
    values: |
      resources:
        - apiVersion: v1
          kind: ConfigMap
          metadata:
            name: my-config
            namespace: some-namespace
          data:
            key: value
```

---

## GitOps - ArgoCD

The `gitops/` directory implements the **App of Apps** pattern: a single root Application bootstraps ArgoCD, which then discovers and reconciles all other applications declared in the repo.

![ArgoCD Applications](docs/images/ArgoCD%20UI.png)

```
gitops/
├── bootstrap/
│   └── root-app.yaml                    # Root Application - syncs all manifests under gitops/
├── app/
│   └── simple-time-service.yaml         # ApplicationSet - deploys Helm chart to each registered cluster
├── prometheus/
│   └── prometheus.yaml                  # ApplicationSet - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
├── metrics-server/
│   └── metrics-server.yaml              # ApplicationSet - metrics-server (required for HPA)
├── grafana/
│   └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap via charts/raw
├── alerts/
│   ├── simple-time-service-alerts.yaml  # ApplicationSet - PrometheusRule (alert expressions)
│   └── alertmanager-slack.yaml          # ApplicationSet - AlertmanagerConfig (Slack routing)
├── loki/
│   ├── loki.yaml                        # ApplicationSet - Loki single-binary log store (logging namespace)
│   └── grafana-loki-datasource.yaml     # ApplicationSet - Grafana Loki datasource ConfigMap via charts/raw
└── fluent-bit/
    └── fluent-bit.yaml                  # ApplicationSet - Fluent Bit DaemonSet (log collector → Loki)
```

### How it works

1. **Root Application** (`gitops/bootstrap/root-app.yaml`) - deployed manually once. It points at the `gitops/` path in the repo and syncs all `Application` and `ApplicationSet` manifests defined there.
2. **ApplicationSet** (`gitops/app/simple-time-service.yaml`) - discovered automatically by the root app. Uses the cluster generator to deploy the `charts/simple-time-service` Helm chart to every cluster registered in ArgoCD. HPA is enabled via a Helm value override in this file:
   ```yaml
   hpa:
     enabled: true
   ```
3. **Prometheus ApplicationSet** (`gitops/prometheus/prometheus.yaml`) - discovered automatically by the root app. Deploys the `kube-prometheus-stack` Helm chart to every registered cluster, providing Prometheus, Grafana, and Alertmanager in the `monitoring` namespace.
4. **metrics-server ApplicationSet** (`gitops/metrics-server/metrics-server.yaml`) - discovered automatically by the root app. Deploys `metrics-server` into `kube-system` on every registered cluster, which is a prerequisite for the Kubernetes HPA to collect CPU/memory utilization data.
5. **grafana-dashboards ApplicationSet** (`gitops/grafana/simple-time-service-dashboard.yaml`) - discovered automatically by the root app. Uses the generic `charts/raw` Helm chart to deploy a Grafana dashboard ConfigMap into the `monitoring` namespace on every registered cluster. The ConfigMap carries the `grafana_dashboard: "1"` label so Grafana's sidecar auto-imports it. A sync-wave annotation (`argocd.argoproj.io/sync-wave: "2"`) ensures this deploys after the `monitoring` namespace exists.
6. **simple-time-service-alerts ApplicationSet** (`gitops/alerts/simple-time-service-alerts.yaml`) - discovered automatically by the root app. Uses `charts/raw` to deploy a `PrometheusRule` CRD containing alerting expressions for `SimpleTimeServiceDown` and `SimpleTimeServiceHPAAtMaxReplicas`. The rule carries the label `notify: slack` which Prometheus propagates to every alert it fires.
7. **alertmanager-slack ApplicationSet** (`gitops/alerts/alertmanager-slack.yaml`) - discovered automatically by the root app. Uses `charts/raw` to deploy an `AlertmanagerConfig` CRD that routes alerts with `notify=slack` to a Slack channel. The webhook URL is read from a Kubernetes Secret (`slack-webhook-url`) and never stored in git. This app will show as degraded until the secret is applied.
8. **loki ApplicationSet** (`gitops/loki/loki.yaml`) - discovered automatically by the root app. Deploys the [Loki Helm chart](https://grafana-community.github.io/helm-charts) in `SingleBinary` mode into the `logging` namespace. Configured with filesystem storage and a single replica (suitable for demos). A sync-wave annotation (`argocd.argoproj.io/sync-wave: "3"`) ensures Loki is running before Fluent Bit and the datasource are applied.
9. **fluent-bit ApplicationSet** (`gitops/fluent-bit/fluent-bit.yaml`) - discovered automatically by the root app. Deploys Fluent Bit as a DaemonSet in the `logging` namespace. It tails `/var/log/containers/*.log` on every node, enriches log entries with Kubernetes metadata (namespace, pod, container), and forwards them to Loki at `http://loki-gateway.logging.svc.cluster.local`. Sync-wave `"4"` ensures it deploys after Loki.
10. **grafana-loki-datasource ApplicationSet** (`gitops/loki/grafana-loki-datasource.yaml`) - discovered automatically by the root app. Uses `charts/raw` to deploy a ConfigMap with label `grafana_datasource: "1"` into the `monitoring` namespace. Grafana's sidecar detects this label and provisions a Loki datasource pointing at `http://loki-gateway.logging.svc.cluster.local`. Sync-wave `"4"` ensures the datasource is registered only after Loki is ready.

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

ArgoCD begins reconciling the `gitops/` directory. Within the default polling interval (up to 3 minutes) it discovers `gitops/app/simple-time-service.yaml` and creates the `ApplicationSet`, which in turn provisions the `simple-time-service` application on every registered cluster.

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

## Autoscaling - HPA and metrics-server

### metrics-server

`metrics-server` aggregates CPU and memory usage from the Kubelets and exposes them via the Kubernetes Metrics API (`metrics.k8s.io`). It is a hard prerequisite for the HPA controller to function - without it, the HPA cannot read pod utilization and no scaling decisions are made.

It is deployed into `kube-system` via ArgoCD using the [metrics-server Helm chart](https://github.com/kubernetes-sigs/metrics-server). Two flags are set to make it work correctly on EKS:

| Flag | Reason |
|------|--------|
| `--kubelet-preferred-address-types=InternalIP` | EKS node hostnames are not resolvable inside the cluster; using the internal IP avoids DNS lookup failures |
| `--kubelet-insecure-tls` | Skips kubelet TLS verification - acceptable for demos; configure proper CA certs in production |

Verify it is running:

```bash
kubectl top pods -n simple-time-service
kubectl top nodes
```

### HorizontalPodAutoscaler

The Helm chart includes an optional HPA (`charts/simple-time-service/templates/hpa.yaml`). It is **disabled by default** in `values.yaml` and enabled via a Helm value override in the ArgoCD ApplicationSet (`gitops/app/simple-time-service.yaml`):

```yaml
hpa:
  enabled: true
```

When enabled, the HPA targets 70% average CPU utilization and scales between 2 and 10 replicas. The `replicas` field is omitted from the Deployment when HPA is active to prevent the Deployment controller and HPA from conflicting over the replica count.

Scale-up and scale-down behavior is configurable via `values.yaml`:

| Key | Default | Description |
|-----|---------|-------------|
| `hpa.scaleDown.stabilizationWindowSeconds` | `300` | How long to wait after load drops before scaling down |
| `hpa.scaleDown.pods` | `1` | Max pods to remove per period when scaling down |
| `hpa.scaleDown.periodSeconds` | `60` | Period length for scale-down policy |
| `hpa.scaleUp.stabilizationWindowSeconds` | `0` | How long to wait before scaling up (0 = immediate) |
| `hpa.scaleUp.pods` | `2` | Max pods to add per period when scaling up |
| `hpa.scaleUp.periodSeconds` | `30` | Period length for scale-up policy |

The defaults are deliberately asymmetric: scale-up is fast (add up to 2 pods every 30s with no stabilization delay) to handle spikes quickly, while scale-down is conservative (remove 1 pod per minute, only after 5 minutes of sustained low load) to avoid thrashing.

Verify the HPA after ArgoCD syncs:

```bash
kubectl get hpa -n simple-time-service
```

To observe autoscaling in action, generate load against the service. First forward the port in one terminal:

```bash
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
```

Then run one of the load scripts in another terminal (see the [Load Testing](#load-testing) section for full details):

```bash
# Python (no extra dependencies)
python3 scripts/load_test.py --concurrency 20 --duration 120

# k6 staged scenario
k6 run scripts/k6-staged.js
```

Then watch the HPA react:

```bash
kubectl get hpa -n simple-time-service -w
```

> For a lightweight service like this, CPU utilization rises slowly under light traffic. You may need to sustain the load for a short period before the HPA triggers a scale-out event. Scaling down after load stops is intentionally conservative - the default stabilization window is 5 minutes, configurable via `hpa.scaleDown.stabilizationWindowSeconds`.

---

## Network Policy

Network Policy enforcement is **disabled by default**. Enabling it is a two-step process: first the VPC CNI add-on must be configured to run the Network Policy controller (Terraform change), and then the NetworkPolicy resource itself must be deployed (ArgoCD change).

### Step 1 — Enable the Network Policy controller in the EKS add-on

Open [terraform/modules/eks/main.tf](terraform/modules/eks/main.tf) and uncomment the `configuration_values` block inside the `vpc-cni` add-on:

```hcl
vpc-cni = {
  before_compute = true
  most_recent    = true
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}
```

Then apply the change:

```bash
cd terraform
terraform apply
```

This patches the `vpc-cni` managed add-on to start the Network Policy controller as a sidecar on each node. Without this, any `NetworkPolicy` resource created in the cluster is silently ignored.

### Step 2 — Enable the NetworkPolicy resource in the ArgoCD ApplicationSet

Open [gitops/app/simple-time-service.yaml](gitops/app/simple-time-service.yaml) and change `networkPolicy.enabled` from `false` to `true` in the Helm values override:

```yaml
helm:
  values: |
    networkPolicy:
      enabled: true
```

Commit and push to `main`. ArgoCD will detect the change within the default polling interval (3 minutes) and deploy the `NetworkPolicy` resource, which restricts ingress to traffic from the `monitoring` namespace (Prometheus scraping) and allows all egress.

### Verify

```bash
kubectl get networkpolicy -n simple-time-service
```

---

## Load Testing

Two scripts in `scripts/` generate controlled HTTP traffic for validating Kubernetes HPA behavior and the Prometheus/Grafana observability pipeline.

| Script | Tool | Best for |
|--------|------|----------|
| `scripts/load_test.py` | Python stdlib | Quick, zero-dependency load generation |
| `scripts/k6-staged.js` | k6 | Staged ramping-arrival-rate scenarios with built-in thresholds |

---

### Python load test (`scripts/load_test.py`)

#### Prerequisites

No third-party libraries required - uses only Python's built-in `urllib` and `threading` modules.

| Requirement | Version |
|-------------|---------|
| Python | 3.8+ |

Verify your Python version:

```bash
python3 --version
```

#### Usage

```bash
# Default: 10 workers, 60 s, targeting http://localhost:8080/
python3 scripts/load_test.py

# Custom URL
python3 scripts/load_test.py --url http://localhost:8080/

# Higher concurrency and longer run
python3 scripts/load_test.py --url http://localhost:8080/ --concurrency 20 --duration 120

# Verbose per-request debug logging
python3 scripts/load_test.py --verbose
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | `http://localhost:8080/` | Target URL |
| `--concurrency` | `10` | Number of concurrent worker threads |
| `--duration` | `60` | Test duration in seconds |
| `--verbose` | off | Enable debug-level logging per request |

#### Output

At the end of the run the script logs a summary:

```
Load test completed
Total requests: 1234
Successful: 1230
Failed: 4
Average req/sec: 20.57
```

---

### k6 staged load test (`scripts/k6-staged.js`)

#### Prerequisites / Installation

Requires [k6](https://k6.io/docs/get-started/installation/) v0.46+. Quick install: `brew install k6` (macOS) or see the k6 docs for Linux/Windows options.

```bash
k6 version  # verify
```

#### Usage

```bash
# Default target: http://localhost:8080
k6 run scripts/k6-staged.js

# Custom target URL
BASE_URL=http://localhost:8080 k6 run scripts/k6-staged.js
```

#### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://localhost:8080` | Base service URL |

#### Traffic profile

The script uses the `ramping-arrival-rate` executor. Each iteration sends two batched requests: `GET /` and `GET /health`. Note that the Grafana dashboard filters out `/health` from all traffic panels, so only the `GET /` requests appear in request rate and latency views.

| Stage | Target rate | Duration |
|-------|-------------|----------|
| Warm-up | 50 req/s | 30 s |
| Ramp up | 50 → 100 req/s | 1 m |
| Peak | 100 → 200 req/s | 1 m |
| Ramp down | 200 → 0 req/s | 30 s |

Pre-allocated VUs: 100 (max: 300)

#### Thresholds

k6 exits with a non-zero status code if either threshold is breached, making it suitable for CI gates.

| Metric | Threshold |
|--------|-----------|
| `http_req_failed` | < 10 % error rate |
| `http_req_duration` | p(95) < 2000 ms |

---

## Monitoring - Prometheus, Grafana, and Alertmanager

The `gitops/prometheus/prometheus.yaml` ApplicationSet deploys the [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm chart to every cluster registered in ArgoCD.

### What gets deployed

| Component | Details |
|-----------|---------|
| Prometheus | Metrics collection with a 7-day retention window |
| Grafana | Dashboards UI, auto-provisioned with the Prometheus data source and a Loki datasource (added via `gitops/loki/grafana-loki-datasource.yaml`) |
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
    serviceMonitorSelectorNilUsesHelmValues: false

prometheusOperator:
  tls:
    enabled: false
  admissionWebhooks:
    enabled: false
```

TLS and admission webhooks on the operator are disabled to simplify initial cluster setup. Enable them in production environments for additional security.

`serviceMonitorSelectorNilUsesHelmValues: false` tells Prometheus to discover `ServiceMonitor` resources across **all namespaces**, not just the `monitoring` namespace where Prometheus itself runs. Without this, `ServiceMonitor` resources created in `simple-time-service` (or any other namespace) are silently ignored.

> **Where do these metrics come from?**
> `kube-state-metrics` is deployed automatically as part of the `kube-prometheus-stack` Helm chart used in this repo. It exposes Kubernetes object/state metrics such as Deployments, Pods, replica counts, and resource requests/limits.
> This is what powers dashboard panels like **Available Replicas**, **Total Pods**, **CPU Request vs Usage**, and **Memory Request/Limit vs Usage**.
> Actual container CPU and memory usage come from kubelet/cAdvisor metrics scraped by Prometheus. cAdvisor is embedded in the kubelet on each node rather than deployed as a separate application.

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

### SimpleTimeService Grafana dashboard

![Grafana Dashboard](docs/images/Grafana%20Dashboard.png)

A pre-built dashboard is automatically provisioned into Grafana via the `gitops/grafana/simple-time-service-dashboard.yaml` ApplicationSet. It uses the generic `charts/raw` Helm chart to deploy a ConfigMap with label `grafana_dashboard: "1"` into the `monitoring` namespace. Grafana's sidecar detects the label and imports the dashboard without any manual steps.

The dashboard (UID `simple-time-service`, auto-refreshes every 30 seconds) contains 12 panels organized into five rows:

**Row 1 - Status overview (stat panels)**

| Panel | Query | Notes |
|-------|-------|-------|
| Scrape Status | `min(up{job=~".*simple-time-service.*"})` | Displays "Up" / "Down" - reflects Prometheus scrape availability, not uptime duration |
| Available Replicas | `kube_deployment_status_replicas_available{namespace="simple-time-service"}` | |
| Total Pods | `count(kube_pod_info{namespace="simple-time-service", pod=~"simple-time-service-.*"})` | |
| Requests (Last 5m) | `sum(increase(http_requests_total{...}[5m]))` | Excludes `/metrics` and `/health` |

**Row 2 - Traffic**

| Panel | Query | Unit |
|-------|-------|------|
| Request Rate | `sum(rate(http_request_duration_seconds_count{...}[5m]))` | req/s |
| Latency | `histogram_quantile` p50 / p95 / p99 on `http_request_duration_seconds_bucket` | seconds |

**Row 3 - Request activity**

| Panel | Query | Unit |
|-------|-------|------|
| Request Activity | `sum(rate(http_request_duration_seconds_count{...}[1m]))` | req/s |
| Request Count by Status | `sum by(status)(increase(http_requests_total{...}[5m]))` | count |

**Row 4 - CPU**

| Panel | Query | Unit |
|-------|-------|------|
| CPU Request vs Usage | actual usage vs `kube_pod_container_resource_requests{resource="cpu"}` | cores |
| CPU Limit vs Usage | actual usage vs `kube_pod_container_resource_limits{resource="cpu"}` | cores |

**Row 5 - Memory**

| Panel | Query | Unit |
|-------|-------|------|
| Memory Request vs Usage (MiB) | working set bytes vs `kube_pod_container_resource_requests{resource="memory"}` | MiB |
| Memory Limit vs Usage (MiB) | working set bytes vs `kube_pod_container_resource_limits{resource="memory"}` | MiB |

The HTTP traffic panels (rows 2–3) show **No data** until the ServiceMonitor is enabled and the service has received traffic on a non-excluded handler. Note that `/health` and `/metrics` requests are filtered out by all traffic queries, so hitting only those paths will not populate the panels - send requests to `/` instead. The infrastructure panels (rows 1, 4–5) populate from `kube-state-metrics` and `cAdvisor` regardless of the ServiceMonitor. Panels populate automatically once the relevant metrics are flowing - no manual import or restart is needed.

> To add more dashboards, append additional `ConfigMap` entries to the `resources:` list in `gitops/grafana/simple-time-service-dashboard.yaml`.

---

### Verify the ServiceMonitor is working

> This section applies only when the service is deployed with `serviceMonitor.enabled=true` and the `latest` image tag (which exposes the `/metrics` endpoint).

**1. Confirm the ServiceMonitor resource exists:**

```bash
kubectl get servicemonitor -n simple-time-service
# Should show: simple-time-service
```

**2. Check Prometheus has picked it up as a scrape target:**

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Open [http://localhost:9090/targets](http://localhost:9090/targets) and look for a target matching `simple-time-service`. It should show **State: UP**.

> If the target is missing, the most common cause is a label mismatch. `kube-prometheus-stack` configures Prometheus with `serviceMonitorSelectorNilUsesHelmValues: false` in this repo, which means Prometheus discovers `ServiceMonitor` resources across all namespaces. If you changed this value, ensure the `ServiceMonitor` labels match the `serviceMonitorSelector` on the Prometheus CR.

**3. Query a metric to confirm data is flowing:**

In the Prometheus UI ([http://localhost:9090](http://localhost:9090)), run:

```promql
http_requests_total
```

You should see time-series with labels like `handler="/"` and `method="GET"`. If the result is empty, the service has not received any requests yet - send a few with `curl` and re-query.

**4. Quick end-to-end check via curl:**

```bash
# Forward the service in one terminal
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80

# Hit the endpoint a few times to generate metrics
curl http://localhost:8080/
curl http://localhost:8080/health

# Then check the raw metrics output
curl http://localhost:8080/metrics | grep http_requests_total
```

---

## Alerting

Alerting is split across two ArgoCD apps in `gitops/alerts/`:

| App | File | Purpose |
|-----|------|---------|
| `simple-time-service-alerts` | `simple-time-service-alerts.yaml` | Deploys the `PrometheusRule` CRD with alert expressions |
| `alertmanager-slack` | `alertmanager-slack.yaml` | Deploys the `AlertmanagerConfig` CRD for Slack routing |

### PrometheusRules

| Alert | Condition | Severity |
|-------|-----------|----------|
| `SimpleTimeServiceDown` | Scrape target unreachable for 1m | critical |
| `SimpleTimeServiceHPAAtMaxReplicas` | HPA at max replicas (10) for 5m | warning |

The `PrometheusRule` carries the label `notify: slack`, which Prometheus propagates to every alert it fires. The Slack route matches on this label - so any future alert added to the same rule automatically routes to Slack without changing the route config. Any PrometheusRule in any namespace can opt into Slack by adding the same label.

### Slack notifications (optional)

The `alertmanager-slack` app deploys an `AlertmanagerConfig` CRD that:
- Routes only alerts with `notify=slack` to Slack (ignores unrelated cluster alerts)
- Reads the webhook URL from a Kubernetes Secret (`slack-webhook-url`) - never from git
- Uses `alertmanagerConfigMatcherStrategy: None` so the route is not restricted to a single namespace

The stack deploys without the secret - only the `alertmanager-slack` app will show as degraded in ArgoCD. Alertmanager itself runs fine with its default config.

**To enable Slack notifications:**

```bash
cp secrets/alertmanager-config.example.yaml secrets/slack-webhook-url.yaml
# Edit secrets/slack-webhook-url.yaml and paste your Slack incoming webhook URL
kubectl apply -f secrets/slack-webhook-url.yaml -n monitoring
argocd app sync alertmanager-slack-simple-eks
```

The Prometheus Operator picks up the secret immediately - no restart required.

> `secrets/slack-webhook-url.yaml` is gitignored. Never commit it.

### EKS false positives suppressed

`KubeSchedulerDown` and `KubeControllerManagerDown` are disabled in `prometheus.yaml`. On EKS the control plane is managed by AWS and is never exposed for Prometheus scraping, so these alerts would fire permanently and add noise.

### Testing the Slack receiver

To verify the Alertmanager → Slack path without touching any cluster resources:

```bash
# 1. Port-forward Alertmanager
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093

# 2. Fire a fake alert (in a second terminal)
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels":      {"alertname":"TestAlert","severity":"critical","notify":"slack"},
    "annotations": {"summary":"Test alert","description":"Verifying Slack receiver works"}
  }]'
```

The alert appears in `#alerts-test` within 30 seconds and auto-resolves after 5 minutes.

> The `notify: slack` label is required - the Slack route only matches alerts carrying that label.

![Slack Alert](docs/images/Alert.png)

<details>
<summary><strong>Operational notes - silencing, inhibition, and grouping</strong></summary>

### Silencing alerts

Silences temporarily suppress alerts without deleting or modifying rules. Useful during maintenance windows or known incidents.

**Via the Alertmanager UI:**

```bash
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093
# Open http://localhost:9093 → Silences → New Silence
```

**Via the API:**

```bash
# Silence all simple-time-service alerts for 2 hours
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
UNTIL=$(date -u -v+2H +"%Y-%m-%dT%H:%M:%SZ")  # macOS
# UNTIL=$(date -u -d '+2 hours' +"%Y-%m-%dT%H:%M:%SZ")  # Linux

curl -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d "{
    \"matchers\": [{\"name\":\"notify\",\"value\":\"slack\",\"isRegex\":false}],
    \"startsAt\":  \"$NOW\",
    \"endsAt\":    \"$UNTIL\",
    \"comment\":   \"Maintenance window\",
    \"createdBy\": \"nabeem\"
  }"
```

To silence a specific alert, change the matcher to `alertname`:

```bash
curl -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d "{
    \"matchers\": [{\"name\":\"alertname\",\"value\":\"SimpleTimeServiceDown\",\"isRegex\":false}],
    \"startsAt\":  \"$NOW\",
    \"endsAt\":    \"$UNTIL\",
    \"comment\":   \"Known issue - investigating\",
    \"createdBy\": \"nabeem\"
  }"
```

Silences are stored in Alertmanager only - not persisted to git and lost if the pod restarts.

### Inhibition rules

Configured automatically by `kube-prometheus-stack`. When a `critical` alert fires for a given `alertname` + `namespace`, Alertmanager suppresses `warning` and `info` alerts for the same pair, preventing alert storms.

### Grouping

Alerts with the same `alertname` + `namespace` are batched into a single Slack message. Timing is controlled by the `AlertmanagerConfig` route:

| Setting | Value | Meaning |
|---------|-------|---------|
| `groupWait` | 30s | Wait 30s before sending the first notification |
| `groupInterval` | 5m | Wait 5m before notifying on an updated group |
| `repeatInterval` | 4h | Re-notify every 4h if still firing |

</details>

---

## Log Aggregation - Loki, Fluent Bit, and Grafana datasource

Container logs are collected, shipped to a central store, and made queryable in Grafana without any manual configuration steps.

### Architecture

```
[Each node] Fluent Bit DaemonSet
    │  tails /var/log/containers/*.log
    │  enriches with Kubernetes labels
    ▼
loki-gateway.logging.svc.cluster.local  (Loki HTTP ingestion endpoint)
    │
    ▼
Loki (SingleBinary, logging namespace)
    │  stores logs on emptyDir volume
    ▼
Grafana datasource (ConfigMap, monitoring namespace)
    │  auto-provisioned by grafana-sidecar
    ▼
Grafana → Explore → Loki queries (LogQL)
```

### What gets deployed

| Component | Helm chart | Namespace | Sync wave |
|-----------|-----------|-----------|-----------|
| Loki | `grafana-community/loki` `6.56.1` | `logging` | 3 |
| Fluent Bit | `fluent/fluent-bit` `0.48.9` | `logging` | 4 |
| Grafana Loki datasource | `charts/raw` (ConfigMap) | `monitoring` | 4 |

### Loki configuration

Loki runs in `SingleBinary` mode with one replica. This is the simplest topology and is suitable for development and demo environments.

> **Ephemeral storage:** Logs are stored on an `emptyDir` volume and are **permanently lost when the Loki pod restarts**. This is intentional for a demo - replace with an S3/GCS object store before using this in any persistent environment.

| Setting | Value | Notes |
|---------|-------|-------|
| Deployment mode | `SingleBinary` | All Loki components in one pod |
| Storage | `filesystem` (emptyDir) | Logs are lost on pod restart - use S3/GCS in production |
| Replication factor | `1` | No redundancy - acceptable for demos |
| Schema | `v13` (TSDB, `2024-01-01`) | Current recommended schema |
| Auth | disabled (`auth_enabled: false`) | Single-tenant mode |
| Gateway | enabled | Exposes `loki-gateway` ClusterIP service used by Fluent Bit and Grafana |
| Backend / Read / Write replicas | `0` | Disabled - SingleBinary handles everything |

### Fluent Bit configuration

Fluent Bit runs as a DaemonSet (one pod per node) in the `logging` namespace.

**Input:** `tail` plugin reads all container logs from `/var/log/containers/*.log` using the `docker` and `cri` multiline parsers.

**Filter:** `kubernetes` plugin enriches each log record with metadata including namespace, pod name, container name, and other Kubernetes labels.

**Output:** `loki` plugin forwards enriched logs to the Loki gateway. Labels are set inline using the `$kubernetes[...]` record accessor. Labels used:

| Label | Value |
|-------|-------|
| `job` | `fluent-bit` |
| `namespace` | `$kubernetes['namespace_name']` |
| `pod` | `$kubernetes['pod_name']` |
| `container` | `$kubernetes['container_name']` |

### Grafana Loki datasource

The datasource is provisioned automatically via a ConfigMap with label `grafana_datasource: "1"` in the `monitoring` namespace. Grafana's sidecar detects this label and loads the datasource configuration without any manual steps.

| Setting | Value |
|---------|-------|
| Name | `Loki` |
| Type | `loki` |
| URL | `http://loki-gateway.logging.svc.cluster.local` |
| Default datasource | No (Prometheus remains the default) |

### Querying logs in Grafana

![Loki Logs](docs/images/logs.png)

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open [http://localhost:3000](http://localhost:3000), navigate to **Explore**, and select the **Loki** datasource. Example LogQL queries:

```logql
# All logs from the simple-time-service namespace
{namespace="simple-time-service"}

# Logs from a specific container
{namespace="simple-time-service", container="simple-time-service"}

# Filter for error-level log lines
{namespace="simple-time-service"} |= "ERROR"
```

### Verify Loki is receiving logs

```bash
# Check pods are running
kubectl get pods -n logging

# Port-forward the Loki gateway
kubectl port-forward svc/loki-gateway -n logging 3100:80

# Query recent logs via the Loki API
curl 'http://localhost:3100/loki/api/v1/labels'
```

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
docker build -t simple-time-service ./app
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

The manifest at `k8s/microservice.yaml` contains both a `Deployment` and a `ClusterIP` `Service`. No namespace is specified in the manifest, so resources are deployed into whichever namespace your current kubectl context is set to (typically `default`). This is a quick-start path only - the Helm chart deployed via ArgoCD uses the `simple-time-service` namespace. A single command is all that is needed:

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

The workflow at `.github/workflows/app-image.yaml` automatically builds and pushes the Docker image to Docker Hub.

### Triggers

| Event | Condition | Behaviour |
|-------|-----------|-----------|
| Push to `main` | Files under `app/**` or the workflow file changed | Build + push |
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
  --push ./app
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
# Delete the root app
kubectl delete -f gitops/bootstrap/root-app.yaml
```

With the current sync policy (`prune: true`) and ArgoCD finalizer behavior, child apps and their managed resources should be cleaned up - but verify in the UI or with `kubectl get ns` before uninstalling ArgoCD, as behavior can vary depending on finalizer state.

### 2 - Uninstall ArgoCD

```bash
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

### 3 - Remove the Helm release (if deployed outside ArgoCD)

```bash
# If installed into the default namespace:
helm uninstall simple-time-service

# If installed into a custom namespace (e.g. simple-time-service):
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

## NetworkPolicy

The Helm chart includes an optional NetworkPolicy (`charts/simple-time-service/templates/networkpolicy.yaml`). It is **disabled by default** in `values.yaml` and enabled via the ArgoCD ApplicationSet override.

When enabled, it applies a default-deny posture and then opens only the minimum required traffic:

| Direction | Allowed | Reason |
|-----------|---------|--------|
| Ingress | Port 8080 from any pod in the same namespace | Pod-to-pod traffic within `simple-time-service` |
| Ingress | Port 8080 from the `monitoring` namespace | Prometheus scraping via ServiceMonitor |
| Egress | Port 53 UDP/TCP | DNS resolution |
| Everything else | Denied | The app makes no outbound calls |

> **CNI requirement:** NetworkPolicy enforcement requires a CNI plugin that supports it. This repo enables the VPC CNI Network Policy controller via `enableNetworkPolicy: "true"` in the `vpc-cni` add-on configuration (`terraform/modules/eks/main.tf`), so no additional Terraform changes are required.

Verify the policy after ArgoCD syncs:

```bash
kubectl get networkpolicy -n simple-time-service
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
| `/metrics` | GET | Prometheus metrics (available on `latest` tag only - see table below) |

### Prometheus metrics exposed

Metrics are emitted by [`prometheus-fastapi-instrumentator`](https://github.com/trallnag/prometheus-fastapi-instrumentator) and the standard Python `prometheus_client` collectors.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `http_requests_total` | Counter | `method`, `handler`, `status` | Total HTTP requests completed |
| `http_request_duration_seconds` | Histogram | `method`, `handler` | Request latency distribution (use for p50/p95/p99) |
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
| Service not reachable from localhost | The Service type is `ClusterIP`. Use `kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80` to reach it locally. |
| `simple-time-service` ServiceMonitor not appearing in Prometheus targets | By default, Prometheus only discovers `ServiceMonitor` resources in the `monitoring` namespace. Set `serviceMonitorSelectorNilUsesHelmValues: false` in `prometheusSpec` (see [prometheus.yaml](gitops/prometheus/prometheus.yaml)) so Prometheus watches all namespaces. Also confirm `serviceMonitor.enabled: true` is set in the app's Helm values (see [simple-time-service.yaml](gitops/app/simple-time-service.yaml)). Verify with `kubectl get servicemonitor -n simple-time-service`. |
| `kubectl top pods` returns `error: Metrics API not available` | `metrics-server` is not running or not yet ready. Check with `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server`. If ArgoCD has not synced yet, trigger a manual sync. |
| HPA shows `<unknown>/70%` for CPU utilization | `metrics-server` is not available or the pods have no CPU requests set. Verify `kubectl top pods -n simple-time-service` works and that `resources.requests.cpu` is defined in `values.yaml`. |
| HPA is not scaling despite high load | Confirm `hpa.enabled: true` is set in the ArgoCD ApplicationSet override ([simple-time-service.yaml](gitops/app/simple-time-service.yaml)) and that ArgoCD has synced. Check `kubectl describe hpa simple-time-service -n simple-time-service` for events. |
| Slack alerts not arriving | 1. Confirm the secret exists: `kubectl get secret slack-webhook-url -n monitoring`. 2. Check the `AlertmanagerConfig` is loaded: `kubectl describe alertmanagerconfig slack -n monitoring`. 3. Verify the Prometheus Operator picked it up: `kubectl logs -n monitoring deployment/prometheus-kube-prometheus-operator \| grep -i slack`. 4. Ensure the alert label `notify: slack` is present - the route only matches alerts carrying that label. |
| `alertmanager-slack` ArgoCD app is degraded | The `slack-webhook-url` secret is missing. Apply it with `kubectl apply -f secrets/slack-webhook-url.yaml -n monitoring` then run `argocd app sync alertmanager-slack-simple-eks`. |