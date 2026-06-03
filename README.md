# EKS GitOps Platform

A realistic EKS GitOps reference implementation - not a drop-in production platform, but a working end-to-end example of how one could be built.

It covers the full lifecycle from infrastructure provisioning to GitOps-managed deployments, observability, autoscaling, backup/restore, policy enforcement, and centralized logging. Deliberate demo trade-offs are documented so the boundary between learning environment and production hardening is explicit.

**Who this is for:** engineers who want a concrete, opinionated starting point for EKS + GitOps - something closer to real-world platform complexity than a tutorial, while still making the cost and operational shortcuts clear so you know exactly what to harden before taking it further.

| Component | What it does |
|-----------|-------------|
| **SimpleTimeService** | Minimal Python microservice - returns timestamp + caller IP as JSON |
| **Terraform** | Provisions AWS VPC, EKS cluster, IRSA roles, Karpenter, S3 buckets for Thanos, Loki, and Velero, and Secrets Manager secrets |
| **ArgoCD (App of Apps)** | GitOps engine - self-managed via Helm, all platform components reconcile from this repo |
| **AWS Load Balancer Controller** | Provisions ALB Ingress for services and ArgoCD |
| **EBS CSI Driver** | Provisions EBS volumes for stateful workloads (Prometheus, Thanos); creates `gp3` as the default StorageClass |
| **External DNS** | Creates Route53 DNS records from Ingress/Service annotations |
| **Cluster Autoscaler** | Scales the managed node group based on pending pods |
| **Karpenter** | Provisions workload nodes on-demand (`t3a.medium` / `c6a.large`) |
| **External Secrets Operator** | Syncs AWS Secrets Manager secrets into Kubernetes Secrets |
| **Reloader** | Rolls Deployments automatically when referenced Secrets or ConfigMaps change |
| **Prometheus + Grafana** | Metrics collection, pre-built dashboard, Slack alerting. Grafana is publicly accessible via ALB ingress; Prometheus and Alertmanager have no ingress and are accessible via `kubectl port-forward` only. |
| **Prometheus CRDs** | Prometheus Operator CRDs managed as a separate ArgoCD app (sync-wave 0) to allow safe CRD upgrades |
| **Prometheus Adapter** | Exposes Prometheus metrics via the Kubernetes custom metrics API, enabling custom-metric HPA |
| **Thanos** | Long-term metric storage - Prometheus sidecar ships data to S3; Query, Compactor, and StoreGateway provide durable retention |
| **HPA + metrics-server** | Horizontal pod autoscaling based on CPU utilization |
| **Loki + Fluent Bit** | Centralized log aggregation backed by S3 object storage, queryable in Grafana |
| **Velero** | Cluster backup and restore - backs up Kubernetes resources and EBS volume snapshots to S3 |
| **Kyverno** | Admission controller - evaluates `ClusterPolicy` rules on every pod admission and writes `PolicyReport` objects; all policies run in Audit mode by default |
| **Policy Reporter** | Web UI for Kyverno `PolicyReport` and `ClusterPolicyReport` objects - accessible via `kubectl port-forward` |

> **Name mapping:** `SimpleTimeService` = source in `app/` = Helm release `simple-time-service` = manifest in `k8s/microservice.yaml`. All the same thing.

---

## Security

> This platform implements IRSA for every workload, secrets via AWS Secrets Manager + External Secrets Operator, pod security contexts (non-root, read-only filesystem, all capabilities dropped), Kyverno admission policies, Trivy and Checkov scanning in CI, and ArgoCD AppProjects that restrict workload deployments to their own namespaces.

See [docs/security.md](docs/security.md) for a full inventory of implemented controls and the production hardening roadmap.

---

## Cost

> Running this stack continuously costs roughly **$310–330/month** at idle (on-demand, ap-south-1). Under active load expect **$400–500/month**. Tear down the cluster when not in use (`./scripts/cleanup.sh` from `terraform/`) - at rest only S3, Route 53, and Secrets Manager accrue charges (under $10/month).

See [docs/cost.md](docs/cost.md) for a full per-component breakdown, cost-control tips, and safe teardown steps.

---

## Documentation

| | |
|-|-|
| [.github/CI.md](.github/CI.md) | CI workflows - triggers, steps, required secrets |
| [.github/branch-protection.md](.github/branch-protection.md) | Branch protection rules and required status checks |
| [app/README.md](app/README.md) | Docker image, CI pipeline, endpoints, container security |
| [terraform/README.md](terraform/README.md) | Infrastructure provisioning, bootstrap module, remote state |
| [charts/namespaces/README.md](charts/namespaces/README.md) | Namespace management chart - creates namespaces and ResourceQuotas from a values list |
| [charts/simple-time-service/README.md](charts/simple-time-service/README.md) | Helm chart values, install/upgrade, examples |
| [charts/raw/README.md](charts/raw/README.md) | Generic chart for deploying arbitrary K8s resources via ApplicationSets |
| [k8s/README.md](k8s/README.md) | Raw Kubernetes manifest (quick-start, no Helm) |
| [scripts/README.md](scripts/README.md) | Load testing with Python and k6 |
| **GitOps** | |
| [gitops/README.md](gitops/README.md) | ArgoCD install, bootstrap, sync policy, application inventory |
| [gitops/argocd/README.md](gitops/argocd/README.md) | AppProjects, least-privilege design, sync wave ordering |
| [gitops/auto-scaling/README.md](gitops/auto-scaling/README.md) | Cluster Autoscaler, Karpenter, NodePool config, metrics-server, HPA |
| [gitops/networking/README.md](gitops/networking/README.md) | AWS Load Balancer Controller, ExternalDNS, Ingress annotations |
| [gitops/secrets/README.md](gitops/secrets/README.md) | External Secrets Operator, ClusterSecretStore, ExternalSecret mappings, Reloader |
| [gitops/storage/README.md](gitops/storage/README.md) | EBS CSI Driver, gp3 StorageClass, PVC inventory |
| [gitops/backup/README.md](gitops/backup/README.md) | Velero, S3 backup location, EBS snapshots, backup and restore commands |
| [gitops/monitoring/README.md](gitops/monitoring/README.md) | Prometheus, Grafana, Thanos, Prometheus Adapter, ServiceMonitor, EBS persistence |
| [gitops/alerts/README.md](gitops/alerts/README.md) | PrometheusRules, Slack alerting, silencing, grouping |
| [gitops/logs/README.md](gitops/logs/README.md) | Loki S3 backend, Fluent Bit, log querying in Grafana |
| [gitops/security/README.md](gitops/security/README.md) | Kyverno policies, Policy Reporter UI, inspecting policy reports |
| **Design** | |
| [docs/design-decisions.md](docs/design-decisions.md) | Why each architectural choice was made - tool selection, configuration defaults, and demo trade-offs |
| [docs/security.md](docs/security.md) | Implemented security controls and production hardening roadmap |
| [docs/cost.md](docs/cost.md) | Monthly cost estimate, cost-control tips, and teardown guidance |
| **Runbooks** | |
| [docs/runbooks/README.md](docs/runbooks/README.md) | 13 operational runbooks - compute, networking, GitOps, observability, secrets, security, backup |

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `~> 1.14` | Provision AWS infrastructure |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Authenticate to AWS |
| Docker | any | Build and run the container locally |
| kubectl | any | Interact with the cluster |
| Helm | `>= 3` | Deploy the chart (bootstrap path only) |
| httpd (`htpasswd`) | any | Generate bcrypt password hashes for bootstrap/upgrade scripts (`brew install httpd` on macOS) |

### ACM certificate (required before bootstrap)

The ALB Ingress for ArgoCD, Grafana, and SimpleTimeService uses HTTPS with HTTP → HTTPS redirect. Prometheus and Alertmanager have no ingress - they are accessed via `kubectl port-forward`. The ALB listener looks up a certificate by domain match, so an ACM certificate covering your domain **must exist and be validated** before running `bootstrap.sh`.

A wildcard certificate is the simplest option - one cert covers all subdomains:

```bash
# Request a wildcard cert for *.platform.<your-domain>
aws acm request-certificate \
  --domain-name "*.platform.<your-domain>" \
  --validation-method DNS \
  --region ap-south-1

# The command returns a CertificateArn. Add the CNAME validation record to Route53:
aws acm describe-certificate \
  --certificate-arn <CertificateArn> \
  --region ap-south-1 \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord"
```

Add the returned CNAME to your Route53 hosted zone and wait for the certificate status to reach `ISSUED` before proceeding:

```bash
aws acm wait certificate-validated \
  --certificate-arn <CertificateArn> \
  --region ap-south-1
```

The ALB controller discovers the certificate automatically by matching the Ingress hostname against ACM-issued certificates in the same region - no ARN needs to be set in the Ingress annotations.

---

## Quick start

Two paths to a running service - pick one.

### Bootstrap path (fastest)

One `terraform apply` provisions the VPC, EKS cluster, and the Helm release. The service is immediately reachable on a public NLB - no ArgoCD required.

```bash
cd terraform/app-bootstrap && terraform init && terraform apply

aws eks update-kubeconfig --region ap-south-1 --name simple-eks

curl $(terraform output -raw application_url)
```

### GitOps path

Terraform provisions infrastructure only. ArgoCD takes over everything else - the service, monitoring, autoscaling, and logging all reconcile from this repo.

```bash
# 1. Set required env vars (Slack webhook required; passwords are auto-generated if omitted)
export TF_VAR_alertmanager_slack_webhook_url="https://hooks.slack.com/..."
# export ARGOCD_ADMIN_PASSWORD="<your-password>"
# export TF_VAR_grafana_admin_password="<your-password>"

# 2. Run the bootstrap script - provisions infra, installs ArgoCD via Helm, applies projects + root app
bash terraform/scripts/bootstrap.sh

# Once complete, services are reachable at:
# ArgoCD:          https://argocd.platform.<your-domain>
# Service:         https://simple-time-service.platform.<your-domain>
# Grafana:         https://grafana.platform.<your-domain>
# Prometheus:      kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
# Alertmanager:    kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093
# Policy Reporter: kubectl port-forward svc/policy-reporter-ui -n security 8080:8080

# 3. Watch ArgoCD reconcile (optional, takes up to 3 minutes for first sync)
kubectl get applications -n argocd -w
```

---

## Upgrading

Use `upgrade.sh` whenever you need to re-apply Terraform changes or rotate secrets on an existing cluster. Unlike `bootstrap.sh` it does **not** reinstall ArgoCD or re-apply the root app - it just runs Terraform, refreshes the ArgoCD cluster secret with the latest outputs, and force-annotates all ExternalSecrets so they re-pull from Secrets Manager.

**When to use it:**
- You changed a Terraform resource and want to apply it
- You want to rotate the ArgoCD admin, Grafana admin, or Alertmanager Slack webhook secret
- The ArgoCD cluster secret is stale (e.g. after a Karpenter instance profile or Thanos, Loki, or Velero bucket name change)

```bash
# Slack webhook is always required
export TF_VAR_alertmanager_slack_webhook_url="https://hooks.slack.com/..."

# Passwords are auto-generated if not set; set them to rotate or pin a specific value
# export ARGOCD_ADMIN_PASSWORD="<plaintext>"          # script hashes it with bcrypt
# export TF_VAR_argocd_admin_password_hash='$2b$...'  # supply a pre-computed bcrypt hash instead
# export TF_VAR_grafana_admin_password="<plaintext>"

bash terraform/scripts/upgrade.sh
```

**What it does:**
1. Validates required tools (`terraform`, `aws`, `kubectl`, `openssl`, `git`, `htpasswd`)
2. Generates or accepts ArgoCD bcrypt hash and Grafana password
3. Runs `terraform init` → `terraform validate` → `terraform apply`
4. Updates kubeconfig
5. Re-applies the ArgoCD cluster secret with the latest Terraform outputs (account ID, VPC ID, domain, Karpenter instance profile, Thanos/Loki/Velero bucket names)
6. Force-annotates `argocd-admin`, `grafana-admin`, and `alertmanager-webhook` ExternalSecrets to trigger an immediate re-sync from Secrets Manager

---

## Validation checklist

| # | What to verify | How |
|---|---------------|-----|
| 1 | Cluster is up | `kubectl get nodes` - all `Ready` |
| 2 | ArgoCD synced *(GitOps path)* | `argocd app get root-app` - `Synced / Healthy` |
| 3 | Service responds | **Bootstrap:** `curl http://$(terraform -chdir=terraform/app-bootstrap output -raw application_url)/` **GitOps:** `curl https://simple-time-service.platform.<your-domain>/` - returns `timestamp` + `ip` JSON |
| 4 | Prometheus scraping | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090` → open `http://localhost:9090/targets` - `simple-time-service` shows `UP` |
| 5 | Grafana dashboard live | Open `https://grafana.platform.<your-domain>` - SimpleTimeService dashboard has data |
| 6 | HPA reacts to load | `kubectl get hpa -n simple-time-service -w` while running `python3 scripts/load_test.py` |
| 7 | Slack alert fires | Fire test alert (see [gitops/alerts/README.md](gitops/alerts/README.md#testing-the-slack-receiver)) - appears in `#alerts-test` within 30s |
| 8 | Loki API reachable | `kubectl port-forward svc/loki-gateway -n logging 3100:80` → `curl 'http://localhost:3100/loki/api/v1/labels'` |
| 9 | Logs in Grafana | Explore → Loki datasource → `{namespace="simple-time-service"}` |
| 10 | Thanos Query healthy | `kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos-query` - `Running`; add Thanos datasource in Grafana pointing to `thanos-query.monitoring.svc:9090` |
| 11 | EBS volumes provisioned | `kubectl get pv` - PVs for Prometheus (20Gi), Alertmanager (2Gi), Thanos Compactor (10Gi), StoreGateway (5Gi) all `Bound` |
| 12 | Velero running | `kubectl get pods -n velero` - `Running`; `kubectl get backupstoragelocation -n velero` - `Available` |
| 13 | Kyverno policies synced | `kubectl get clusterpolicy` - four policies listed; `kubectl get policyreport -A` - reports generated after pod activity |
| 14 | Policy Reporter UI reachable | `kubectl port-forward svc/policy-reporter-ui -n security 8080:8080` → open `http://localhost:8080` |

---

## Project structure

```
.
├── .github/
│   ├── CI.md                                   # CI workflows - triggers, steps, secrets
│   ├── CODEOWNERS                              # Automatic review assignment by path
│   ├── branch-protection.md                    # Branch protection rules and required status checks
│   └── workflows/
│       ├── app-image.yaml                      # CI - build, scan, and push Docker image to Docker Hub
│       ├── terraform-ci.yaml                   # CI - format, validate, lint, and security scan Terraform
│       ├── gitops-ci.yaml                      # CI - helm lint, kubeconform, and yamllint for GitOps manifests
│       ├── actions-check.yaml                  # CI - lint all GitHub Actions workflow files with actionlint
│       ├── codeowners-check.yaml               # CI - validate CODEOWNERS syntax and owner existence
│       └── pr-title-check.yaml                 # CI - enforce Conventional Commits format on PR titles
├── .yamllint.yaml                              # yamllint config - rules for gitops-ci YAML linting
├── compose.yaml                                # Docker Compose for local development
├── app/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── .dockerignore
│   └── src/
│       └── app.py
├── k8s/
│   └── microservice.yaml                       # Deployment + ClusterIP Service (quick-start, no Helm)
├── charts/                                     # READMEs auto-generated by helm-docs (`helm-docs --chart-search-root charts/`)
│   ├── namespaces/                             # Namespace management chart - creates namespaces + ResourceQuotas
│   │   ├── Chart.yaml
│   │   ├── values.yaml                         # Annotated with # -- comments for helm-docs
│   │   ├── README.md                           # Auto-generated - do not edit directly
│   │   ├── README.md.gotmpl                    # helm-docs template - edit this for structural changes
│   │   └── templates/
│   │       ├── namespace.yaml
│   │       └── resourcequota.yaml
│   ├── raw/                                    # Generic chart - renders any K8s resource via .Values.resources
│   │   ├── Chart.yaml
│   │   ├── values.yaml                         # Annotated with # -- comments for helm-docs
│   │   ├── README.md                           # Auto-generated - do not edit directly
│   │   ├── README.md.gotmpl                    # helm-docs template - edit this for structural changes
│   │   └── templates/
│   │       └── resources.yaml
│   └── simple-time-service/                    # Helm chart for the microservice
│       ├── Chart.yaml
│       ├── values.yaml                         # Annotated with # -- comments for helm-docs
│       ├── README.md                           # Auto-generated - do not edit directly
│       ├── README.md.gotmpl                    # helm-docs template - edit this for structural changes
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── ingress.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           ├── networkpolicy.yaml
│           ├── servicemonitor.yaml
│           ├── _helpers.tpl
│           └── NOTES.txt
├── gitops/
│   ├── bootstrap/
│   │   └── root-app.yaml                       # ArgoCD root Application - bootstraps everything below
│   ├── argocd/
│   │   ├── projects/
│   │   │   ├── bootstrap-project.yaml          # AppProject - root-app only, minimal scope
│   │   │   ├── namespaces-project.yaml         # AppProject - cluster namespace lifecycle
│   │   │   ├── platform-project.yaml           # AppProject - ArgoCD, infra, networking, secrets
│   │   │   ├── observability-project.yaml      # AppProject - monitoring, logging, alerting
│   │   │   ├── security-project.yaml           # AppProject - Kyverno admission controller and policy enforcement
│   │   │   └── workloads-project.yaml          # AppProject - application workloads
│   │   ├── argocd.yaml                         # Application - ArgoCD self-managed via Helm
│   │   ├── argocd-admin-secret.yaml            # ApplicationSet - ExternalSecret for ArgoCD admin password
│   │   └── argocd-ingress.yaml                 # ApplicationSet - ALB Ingress at argocd.platform.<domain>
│   ├── namespaces/
│   │   └── cluster-namespaces.yaml             # ApplicationSet - creates all cluster namespaces (wave -1)
│   ├── app/
│   │   └── simple-time-service/
│   │       └── simple-time-service.yaml        # ApplicationSet - Helm deploy with ALB Ingress
│   ├── auto-scaling/
│   │   ├── cluster-autoscaler/
│   │   │   └── cluster-autoscaler.yaml         # ApplicationSet - Cluster Autoscaler
│   │   ├── karpenter/
│   │   │   ├── karpenter.yaml                  # ApplicationSet - Karpenter controller (sync-wave 2)
│   │   │   └── karpenter-nodepools.yaml        # ApplicationSet - EC2NodeClass + NodePool (sync-wave 3)
│   │   └── metrics-server/
│   │       └── metrics-server.yaml             # ApplicationSet - metrics-server (HPA prerequisite)
│   ├── networking/
│   │   ├── ingress-controller/
│   │   │   └── aws-load-balancer-controller.yaml  # ApplicationSet - AWS Load Balancer Controller
│   │   └── external-dns/
│   │       └── external-dns.yaml               # ApplicationSet - ExternalDNS for Route53
│   ├── storage/
│   │   ├── README.md
│   │   └── ebs-csi-driver/
│   │       └── ebs-csi-driver.yaml             # ApplicationSet - AWS EBS CSI Driver (sync-wave 1)
│   ├── backup/
│   │   ├── README.md
│   │   └── velero/
│   │       ├── velero.yaml                     # ApplicationSet - Velero backup and restore (sync-wave 2)
│   │       └── velero-schedule.yaml            # ApplicationSet - daily full-cluster backup Schedule (sync-wave 3)
│   ├── secrets/
│   │   ├── external-secrets/
│   │   │   ├── external-secret-operator.yaml   # ApplicationSet - External Secrets Operator
│   │   │   └── cluster-secret-store.yaml       # ApplicationSet - ClusterSecretStore (sync-wave 2)
│   │   └── reloader/
│   │       └── reloader.yaml                   # ApplicationSet - Stakater Reloader
│   ├── monitoring/
│   │   ├── prometheus/
│   │   │   ├── prometheus-crds.yaml            # ApplicationSet - Prometheus Operator CRDs (sync-wave 0)
│   │   │   ├── prometheus.yaml                 # ApplicationSet - kube-prometheus-stack (sync-wave 4)
│   │   │   └── prometheus-adapter.yaml         # ApplicationSet - custom metrics API bridge (sync-wave 5)
│   │   ├── thanos/
│   │   │   ├── thanos-objstore-secret.yaml     # ApplicationSet - S3 objstore Secret via raw chart (sync-wave 3)
│   │   │   └── thanos.yaml                     # ApplicationSet - Thanos query/compactor/storegateway (sync-wave 6)
│   │   └── grafana/
│   │       ├── grafana-admin-secret.yaml       # ApplicationSet - ExternalSecret for Grafana credentials
│   │       └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap
│   ├── alerts/
│   │   ├── simple-time-service-alerts.yaml     # ApplicationSet - PrometheusRule (alert expressions)
│   │   ├── alertmanager-webhook-secret.yaml    # ApplicationSet - ExternalSecret for Slack webhook
│   │   └── alertmanager-slack.yaml             # ApplicationSet - AlertmanagerConfig (Slack routing)
│   ├── logs/
│   │   ├── loki/
│   │   │   ├── loki.yaml                       # ApplicationSet - Loki single-binary log store (sync-wave 3)
│   │   │   └── grafana-loki-datasource.yaml    # ApplicationSet - Loki datasource ConfigMap (sync-wave 4)
│   │   └── fluent-bit/
│   │       └── fluent-bit.yaml                 # ApplicationSet - Fluent Bit DaemonSet (sync-wave 4)
│   └── security/
│       └── kyverno/
│           ├── kyverno.yaml                    # ApplicationSet - Kyverno admission controller (sync-wave 3)
│           ├── kyverno-policies.yaml           # ApplicationSet - ClusterPolicy rules (sync-wave 5)
│           └── policy-reporter.yaml            # ApplicationSet - Policy Reporter UI (sync-wave 6)
├── scripts/
│   ├── load_test.py                            # Python load generator (no dependencies)
│   └── k6-staged.js                            # k6 staged ramping-arrival-rate scenario
├── docs/
│   ├── design-decisions.md                     # Architectural choices and trade-offs
│   ├── security.md                             # Implemented security controls and production hardening roadmap
│   ├── cost.md                                 # Monthly cost estimate, cost-control tips, and teardown guidance
│   ├── runbooks/                               # 13 operational runbooks (incidents, DR, debugging)
│   └── images/                                 # Screenshots referenced in sub-READMEs
└── terraform/
    ├── main.tf                                 # Root module - wires VPC and EKS modules
    ├── backend.tf                              # S3 remote state
    ├── variables.tf
    ├── terraform.tfvars
    ├── outputs.tf
    ├── providers.tf
    ├── versions.tf
    ├── karpenter.tf                            # Karpenter IAM + EKS Pod Identity association
    ├── cluster-autoscaler-irsa.tf              # IRSA for Cluster Autoscaler
    ├── aws-load-balancer-controller-irsa.tf    # IRSA for AWS Load Balancer Controller
    ├── external-dns-irsa.tf                    # IRSA for ExternalDNS
    ├── external-secrets-irsa.tf                # IRSA for External Secrets Operator
    ├── ebs-csi-driver-irsa.tf                  # IRSA for EBS CSI Driver controller
    ├── thanos.tf                               # S3 bucket + IRSA roles for Thanos Prometheus sidecar, Compactor, StoreGateway
    ├── loki.tf                                 # S3 bucket + IRSA role for Loki object storage
    ├── velero.tf                               # S3 bucket + IRSA role for Velero backups
    ├── secrets-manager.tf                      # AWS Secrets Manager secrets (ArgoCD, Grafana, Slack)
    ├── .tflint.hcl                             # TFLint AWS ruleset plugin config
    ├── .checkov.yaml                           # Checkov global skip rules (documented false positives)
    ├── scripts/                                # Shell scripts for full GitOps lifecycle
    │   ├── bootstrap.sh                        # End-to-end: terraform + ArgoCD Helm + projects + root-app
    │   ├── upgrade.sh                          # Re-apply terraform + refresh cluster secret + force ExternalSecret sync
    │   └── cleanup.sh                          # Tear down ArgoCD apps and destroy infrastructure
    ├── app-bootstrap/                          # One-step Terraform module - infra + Helm release
    │   ├── main.tf
    │   ├── backend.tf
    │   ├── variables.tf
    │   ├── terraform.tfvars
    │   ├── outputs.tf
    │   ├── providers.tf
    │   └── versions.tf
    └── modules/
        ├── vpc/                                # VPC - 2 public + 2 private subnets across 2 AZs
        │   ├── main.tf
        │   ├── variables.tf
        │   └── outputs.tf
        └── eks/                                # EKS 1.34 - managed node group (tainted app=core:NoSchedule)
            ├── main.tf
            ├── variables.tf
            └── outputs.tf
```

---

## Platform Engineering Docs

- [Design Decisions](docs/design-decisions.md) - architectural choices, tool selections, configuration defaults, and demo trade-offs
- [Operational Runbooks](docs/runbooks/README.md) - 13 runbooks covering incidents, DR, and debugging across all platform components

---

## Cleanup

```bash
# GitOps path - the cleanup script removes all ArgoCD apps then destroys infrastructure
bash terraform/scripts/cleanup.sh

# App-bootstrap path
cd terraform/app-bootstrap && terraform destroy
```

The cleanup script runs six steps in order:

1. **Kubernetes resources** - deletes the root app, all ArgoCD Applications and ApplicationSets, Ingresses, LoadBalancer Services, Karpenter NodePools and NodeClaims, PersistentVolumes, and all namespaces labelled `app.kubernetes.io/part-of=eks-gitops-platform` (including `security`) (every namespace created by the `cluster-namespaces` chart)
2. **AWS Load Balancers** - deletes any leftover ALB/NLB/Classic ELBs tagged for the cluster that were not removed by step 1
3. **EBS volumes and snapshots** - deletes EBS volumes tagged `kubernetes.io/cluster/<cluster>=owned` (CSI Driver PVCs with Retain policy), then deletes EBS snapshots tagged for the cluster or with a `velero.io/backup` tag
4. **S3 buckets** - empties all versioned S3 buckets in the same region whose name contains the cluster name (Thanos, Loki, Velero), draining all object versions and delete markers in batches so that Terraform can delete the buckets cleanly
5. **Kyverno CRDs** - deletes all CRDs in the `kyverno.io` and `wgpolicyk8s.io` API groups; this is handled automatically by `cleanup.sh` using a label selector
6. **Terraform destroy** - removes all AWS resources provisioned by Terraform

> The Terraform **state bucket** is not managed by Terraform itself - delete it manually when no longer needed:
> ```bash
> aws s3 rb s3://<your-state-bucket> --force
> ```

---

## Troubleshooting

**Setup issues**

| Symptom | Fix |
|---------|-----|
| `kubectl get nodes` - `Unauthorized` | Re-run `aws eks update-kubeconfig` as the same IAM identity that ran `terraform apply`. |
| ArgoCD apps missing after bootstrap | `argocd app sync root-app` or click **Sync** on the root-app tile in the UI. |
| Service unreachable from localhost | Service type is `ClusterIP` - use `kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80`. |

**Operational issues** - see [`docs/runbooks/`](docs/runbooks/) for full diagnosis and fix steps:

| Symptom | Runbook |
|---------|---------|
| `kubectl top pods` - `Metrics API not available` / HPA shows `<unknown>` | [hpa-not-scaling.md](docs/runbooks/hpa-not-scaling.md) |
| HPA not scaling under load | [hpa-not-scaling.md](docs/runbooks/hpa-not-scaling.md) |
| ServiceMonitor missing from Prometheus targets | [prometheus-target-down.md](docs/runbooks/prometheus-target-down.md) |
| Prometheus Adapter not serving custom metrics | [prometheus-target-down.md](docs/runbooks/prometheus-target-down.md) |
| Grafana shows "No data" across all dashboards | [thanos-no-metrics.md](docs/runbooks/thanos-no-metrics.md) |
| Thanos pods in `CrashLoopBackOff` | [thanos-no-metrics.md](docs/runbooks/thanos-no-metrics.md) |
| Slack alerts not arriving | [alertmanager-not-firing.md](docs/runbooks/alertmanager-not-firing.md) |
| `alertmanager-slack` app degraded in ArgoCD | [alertmanager-not-firing.md](docs/runbooks/alertmanager-not-firing.md) · [external-secrets-not-syncing.md](docs/runbooks/external-secrets-not-syncing.md) |
| Kyverno pods crash-looping / `kubectl get clusterpolicy` returns nothing | [kyverno-policy-violation.md](docs/runbooks/kyverno-policy-violation.md) |
| Policy Reporter UI not loading | [kyverno-policy-violation.md](docs/runbooks/kyverno-policy-violation.md) |
