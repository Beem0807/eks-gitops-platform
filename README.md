# EKS GitOps Platform

A production-style cloud-native platform built on AWS EKS, demonstrating the full lifecycle from infrastructure provisioning to GitOps-managed deployments, observability, autoscaling, and centralized logging.

| Component | What it does |
|-----------|-------------|
| **SimpleTimeService** | Minimal Python microservice - returns timestamp + caller IP as JSON |
| **Terraform** | Provisions AWS VPC, EKS cluster, IRSA roles, Karpenter, S3 bucket for Thanos, and Secrets Manager secrets |
| **ArgoCD (App of Apps)** | GitOps engine - self-managed via Helm, all platform components reconcile from this repo |
| **AWS Load Balancer Controller** | Provisions ALB Ingress for services and ArgoCD |
| **External DNS** | Creates Route53 DNS records from Ingress/Service annotations |
| **Cluster Autoscaler** | Scales the managed node group based on pending pods |
| **Karpenter** | Provisions workload nodes on-demand (`t3a.medium` / `c6a.large`) |
| **External Secrets Operator** | Syncs AWS Secrets Manager secrets into Kubernetes Secrets |
| **Reloader** | Rolls Deployments automatically when referenced Secrets or ConfigMaps change |
| **Prometheus + Grafana** | Metrics collection, pre-built dashboard, Slack alerting (basic auth on Prometheus and Alertmanager UIs) |
| **Prometheus CRDs** | Prometheus Operator CRDs managed as a separate ArgoCD app (sync-wave 0) to allow safe CRD upgrades |
| **Prometheus Adapter** | Exposes Prometheus metrics via the Kubernetes custom metrics API, enabling custom-metric HPA |
| **Thanos** | Long-term metric storage - Prometheus sidecar ships data to S3; Query, Compactor, and StoreGateway provide durable retention |
| **HPA + metrics-server** | Horizontal pod autoscaling based on CPU utilization |
| **Loki + Fluent Bit** | Centralized log aggregation, queryable in Grafana |

> **Name mapping:** `SimpleTimeService` = source in `app/` = Helm release `simple-time-service` = manifest in `k8s/microservice.yaml`. All the same thing.

---

## Documentation

| | |
|-|-|
| [app/README.md](app/README.md) | Docker image, CI pipeline, endpoints, container security |
| [terraform/README.md](terraform/README.md) | Infrastructure provisioning, bootstrap module, remote state |
| [charts/simple-time-service/README.md](charts/simple-time-service/README.md) | Helm chart values, install/upgrade, examples |
| [charts/raw/README.md](charts/raw/README.md) | Generic chart for deploying arbitrary K8s resources via ApplicationSets |
| [k8s/README.md](k8s/README.md) | Raw Kubernetes manifest (quick-start, no Helm) |
| [scripts/README.md](scripts/README.md) | Load testing with Python and k6 |
| [terraform/scripts/](terraform/scripts/) | `bootstrap.sh` — full cluster bring-up; `upgrade.sh` — re-apply Terraform + rotate secrets; `cleanup.sh` — tear everything down |
| **GitOps** | |
| [gitops/README.md](gitops/README.md) | ArgoCD install, bootstrap, sync policy, application inventory |
| [gitops/auto-scaling/README.md](gitops/auto-scaling/README.md) | Cluster Autoscaler, Karpenter, NodePool config, metrics-server, HPA |
| [gitops/networking/README.md](gitops/networking/README.md) | AWS Load Balancer Controller, ExternalDNS, Ingress annotations |
| [gitops/secrets/README.md](gitops/secrets/README.md) | External Secrets Operator, ClusterSecretStore, ExternalSecret mappings, Reloader |
| [gitops/monitoring/README.md](gitops/monitoring/README.md) | Prometheus, Grafana, Thanos, Prometheus Adapter, ServiceMonitor |
| [gitops/alerts/README.md](gitops/alerts/README.md) | PrometheusRules, Slack alerting, silencing, grouping |
| [gitops/logs/README.md](gitops/logs/README.md) | Loki, Fluent Bit, log querying in Grafana |

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

The ALB Ingress for every service (ArgoCD, Grafana, Prometheus, Alertmanager, SimpleTimeService) uses HTTPS with HTTP → HTTPS redirect. The ALB listener looks up a certificate by domain match, so an ACM certificate covering your domain **must exist and be validated** before running `bootstrap.sh`.

A wildcard certificate is the simplest option — one cert covers all subdomains:

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

The ALB controller discovers the certificate automatically by matching the Ingress hostname against ACM-issued certificates in the same region — no ARN needs to be set in the Ingress annotations.

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

# 2. Run the bootstrap script - provisions infra, installs ArgoCD via Helm, applies root app
bash terraform/scripts/bootstrap.sh

# The script prints all credentials at completion. All UIs are accessible via HTTPS:
# ArgoCD:       https://argocd.platform.<your-domain>
# Service:      https://simple-time-service.platform.<your-domain>
# Grafana:      https://grafana.platform.<your-domain>
# Prometheus:   https://prometheus.platform.<your-domain>
# Alertmanager: https://alertmanager.platform.<your-domain>

# 3. Watch ArgoCD reconcile (optional, takes up to 3 minutes for first sync)
kubectl get applications -n argocd -w
```

---

## Upgrading

Use `upgrade.sh` whenever you need to re-apply Terraform changes or rotate secrets on an existing cluster. Unlike `bootstrap.sh` it does **not** reinstall ArgoCD or re-apply the root app — it just runs Terraform, refreshes the ArgoCD cluster secret with the latest outputs, and force-annotates all three ExternalSecrets so they re-pull from Secrets Manager.

**When to use it:**
- You changed a Terraform resource and want to apply it
- You want to rotate the ArgoCD admin, Grafana admin, or Alertmanager Slack webhook secret
- The ArgoCD cluster secret is stale (e.g. after a Karpenter instance profile or Thanos bucket name change)

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
5. Re-applies the ArgoCD cluster secret with the latest Terraform outputs (account ID, VPC ID, domain, Karpenter instance profile, Thanos bucket name)
6. Force-annotates `argocd-admin`, `grafana-admin`, and `alertmanager-webhook` ExternalSecrets to trigger an immediate re-sync from Secrets Manager

---

## Validation checklist

| # | What to verify | How |
|---|---------------|-----|
| 1 | Cluster is up | `kubectl get nodes` - all `Ready` |
| 2 | ArgoCD synced *(GitOps path)* | `argocd app get root-app` - `Synced / Healthy` |
| 3 | Service responds | **Bootstrap:** `curl http://$(terraform -chdir=terraform/app-bootstrap output -raw application_url)/` **GitOps:** `curl https://simple-time-service.platform.<your-domain>/` - returns `timestamp` + `ip` JSON |
| 4 | Prometheus scraping | Open `https://prometheus.platform.<your-domain>/targets` - `simple-time-service` shows `UP` |
| 5 | Grafana dashboard live | Open `https://grafana.platform.<your-domain>` - SimpleTimeService dashboard has data |
| 6 | HPA reacts to load | `kubectl get hpa -n simple-time-service -w` while running `python3 scripts/load_test.py` |
| 7 | Slack alert fires | Fire test alert (see [gitops/alerts/README.md](gitops/alerts/README.md#testing-the-slack-receiver)) - appears in `#alerts-test` within 30s |
| 8 | Loki API reachable | `kubectl port-forward svc/loki-gateway -n logging 3100:80` → `curl 'http://localhost:3100/loki/api/v1/labels'` |
| 9 | Logs in Grafana | Explore → Loki datasource → `{namespace="simple-time-service"}` |
| 10 | Thanos Query healthy | `kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos-query` - `Running`; add Thanos datasource in Grafana pointing to `thanos-query.monitoring.svc:9090` |

---

## Project structure

```
.
├── .github/
│   └── workflows/
│       └── app-image.yaml                      # CI - build and push Docker image to Docker Hub
├── compose.yaml                                # Docker Compose for local development
├── app/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── .dockerignore
│   └── src/
│       └── app.py
├── k8s/
│   └── microservice.yaml                       # Deployment + ClusterIP Service (quick-start, no Helm)
├── charts/
│   ├── raw/                                    # Generic chart - renders any K8s resource via .Values.resources
│   │   ├── Chart.yaml
│   │   └── templates/
│   │       └── resources.yaml
│   └── simple-time-service/                    # Helm chart for the microservice
│       ├── Chart.yaml
│       ├── values.yaml
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
│   │   ├── argocd.yaml                         # Application - ArgoCD self-managed via Helm
│   │   ├── argocd-admin-secret.yaml            # ApplicationSet - ExternalSecret for ArgoCD admin password
│   │   └── argocd-ingress.yaml                 # ApplicationSet - ALB Ingress at argocd.platform.<domain>
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
│   └── logs/
│       ├── loki/
│       │   ├── loki.yaml                       # ApplicationSet - Loki single-binary log store (sync-wave 3)
│       │   └── grafana-loki-datasource.yaml    # ApplicationSet - Loki datasource ConfigMap (sync-wave 4)
│       └── fluent-bit/
│           └── fluent-bit.yaml                 # ApplicationSet - Fluent Bit DaemonSet (sync-wave 4)
├── scripts/
│   ├── load_test.py                            # Python load generator (no dependencies)
│   └── k6-staged.js                            # k6 staged ramping-arrival-rate scenario
├── docs/
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
    ├── thanos.tf                               # S3 bucket + IRSA roles for Thanos Prometheus sidecar, Compactor, StoreGateway
    ├── secrets-manager.tf                      # AWS Secrets Manager secrets (ArgoCD, Grafana, Slack)
    ├── scripts/                                # Shell scripts for full GitOps lifecycle
    │   ├── bootstrap.sh                        # End-to-end: terraform + ArgoCD Helm + root-app
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

## Design notes

These are intentional trade-offs for a demo environment:

- **Single NAT gateway** - reduces cost; use one per AZ in production for fault tolerance.
- **Public EKS API endpoint** - acceptable for demos; restrict `public_access_cidrs` in production.
- **EKS 1.34** - cluster runs Kubernetes 1.34.
- **Core/workload node split** - managed node group nodes are tainted `app=core:NoSchedule` and run system components. Karpenter provisions separate workload nodes (tainted `app=workload:NoSchedule`) for the application. This keeps system stability independent of application scaling.
- **ArgoCD self-managed via Helm** - bootstrapped once by `bootstrap.sh`, then managed as a GitOps app by itself (`gitops/argocd/argocd.yaml`). The initial Helm install is the only manual step.
- **Prometheus Operator TLS and webhooks disabled** - simplifies initial bootstrap reliability.
- **Prometheus CRDs managed separately** - `prometheus-crds.yaml` installs CRDs at sync-wave 0 before `kube-prometheus-stack`, allowing CRD upgrades without touching the operator release.
- **Prometheus and Alertmanager basic auth** - both UIs are protected with bcrypt-hashed credentials provisioned during bootstrap. The hash is stored in Secrets Manager and synced via ExternalSecrets.
- **Thanos long-term retention** - Prometheus ships blocks to an S3 bucket via the Thanos sidecar. Compactor enforces retention (30d raw / 90d 5m / 180d 1h). StoreGateway serves historical queries. Query runs alongside Prometheus for a unified query endpoint.
- **Prometheus Adapter** - bridges Prometheus metrics into the Kubernetes custom metrics API. Enables HPA rules that scale on arbitrary Prometheus queries rather than just CPU/memory.
- **Loki on emptyDir** - logs are ephemeral by design; replace with S3/GCS for any persistent environment.
- **Network Policy disabled by default** - the chart includes a `NetworkPolicy` resource but it is off by default. Enabling it requires two steps: turning on the VPC CNI Network Policy controller in Terraform, then setting `networkPolicy.enabled: true` in the ArgoCD ApplicationSet. See [gitops/README.md](gitops/README.md#network-policy).

---

## Cleanup

```bash
# GitOps path - the cleanup script removes all ArgoCD apps then destroys infrastructure
bash terraform/scripts/cleanup.sh

# App-bootstrap path
cd terraform/app-bootstrap && terraform destroy
```

> The S3 state bucket and Thanos metrics bucket are not removed by `terraform destroy`. Delete them manually when no longer needed:
> ```bash
> aws s3 rb s3://<your-state-bucket> --force
> aws s3 rb s3://<cluster-name>-thanos-metrics-<account-id>-<region> --force
> ```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `kubectl get nodes` - `Unauthorized` | Re-run `aws eks update-kubeconfig` as the same IAM identity that ran `terraform apply`. |
| ArgoCD apps missing after bootstrap | `argocd app sync root-app` or click **Sync** on the root-app tile in the UI. |
| Service unreachable from localhost | Service type is `ClusterIP` - use `kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80`. |
| ServiceMonitor missing from Prometheus targets | Confirm `serviceMonitor.enabled: true` in Helm values and `serviceMonitorSelectorNilUsesHelmValues: false` in `prometheusSpec`. Check with `kubectl get servicemonitor -n simple-time-service`. |
| `kubectl top pods` - `Metrics API not available` | `metrics-server` is not running. Check `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server`. |
| HPA shows `<unknown>/70%` | `metrics-server` unavailable or pods have no CPU requests set. Verify `kubectl top pods -n simple-time-service` works first. |
| HPA not scaling under load | Confirm `hpa.enabled: true` is set in the ApplicationSet override and ArgoCD has synced. Run `kubectl describe hpa simple-time-service -n simple-time-service` for events. |
| Slack alerts not arriving | Check ExternalSecret sync: `kubectl get externalsecret -n monitoring`. Check config: `kubectl describe alertmanagerconfig slack -n monitoring`. Confirm the `notify: slack` label is on the alert. |
| `alertmanager-slack` app degraded in ArgoCD | The Alertmanager webhook ExternalSecret failed to sync. Run `kubectl get externalsecret -n monitoring` and verify the AWS Secrets Manager secret `alertmanager-webhook` exists. |
| Thanos pods in `CrashLoopBackOff` | Check that the `thanos-objstore-config` Secret exists in the `monitoring` namespace: `kubectl get secret thanos-objstore-config -n monitoring`. The `thanos-objstore-secret` ArgoCD app must sync before `thanos`. |
| Prometheus Adapter not serving custom metrics | Run `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1` to verify the API is registered. If empty, check `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter`. |
