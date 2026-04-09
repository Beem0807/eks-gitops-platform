# EKS GitOps Platform

A production-style cloud-native platform built on AWS EKS, demonstrating the full lifecycle from infrastructure provisioning to GitOps-managed deployments, observability, autoscaling, and centralized logging.

| Component | What it does |
|-----------|-------------|
| **SimpleTimeService** | Minimal Python microservice - returns timestamp + caller IP as JSON |
| **Terraform** | Provisions AWS VPC and EKS cluster |
| **ArgoCD (App of Apps)** | GitOps engine - all platform components self-reconcile from this repo |
| **Prometheus + Grafana** | Metrics collection, pre-built dashboard, Slack alerting |
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
| **GitOps** | |
| [gitops/README.md](gitops/README.md) | ArgoCD install, bootstrap, sync policy, autoscaling, network policy |
| [gitops/monitoring/README.md](gitops/monitoring/README.md) | Prometheus, Grafana dashboard, ServiceMonitor verification |
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

---

## Quick start

Two paths to a running service - pick one.

### Bootstrap path (fastest)

One `terraform apply` provisions the VPC, EKS cluster, and the Helm release. The service is immediately reachable on a public NLB - no ArgoCD required.

```bash
cd terraform/bootstrap && terraform init && terraform apply

aws eks update-kubeconfig --region ap-south-1 --name simple-eks

curl $(terraform output -raw application_url)
```

### GitOps path

Terraform provisions infrastructure only. ArgoCD takes over everything else - the service, monitoring, autoscaling, and logging all reconcile from this repo.

```bash
# 1. Provision infrastructure
cd terraform && terraform init && terraform apply

# 2. Connect kubectl
aws eks update-kubeconfig --region ap-south-1 --name simple-eks

# 3. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Bootstrap - this one command starts everything
kubectl apply -f gitops/bootstrap/root-app.yaml

# 5. Watch it come up (takes up to 3 minutes for first reconciliation)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080

# 6. Verify the service
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
curl http://127.0.0.1:8080/

# 7. Verify Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open http://localhost:3000
```

---

## Validation checklist

| # | What to verify | How |
|---|---------------|-----|
| 1 | Cluster is up | `kubectl get nodes` - all `Ready` |
| 2 | ArgoCD synced *(GitOps path)* | `argocd app get root-app` - `Synced / Healthy` |
| 3 | Service responds | **Bootstrap:** `curl http://$(terraform -chdir=terraform/bootstrap output -raw application_nlb_hostname)/` **GitOps:** port-forward then `curl http://127.0.0.1:8080/` - returns `timestamp` + `ip` JSON |
| 4 | Prometheus scraping | Port-forward Prometheus → `http://localhost:9090/targets` - `simple-time-service` shows `UP` |
| 5 | Grafana dashboard live | `http://localhost:3000` - SimpleTimeService dashboard has data |
| 6 | HPA reacts to load | `kubectl get hpa -n simple-time-service -w` while running `python3 scripts/load_test.py` |
| 7 | Slack alert fires | Fire test alert (see [gitops/alerts/README.md](gitops/alerts/README.md#testing-the-slack-receiver)) - appears in `#alerts-test` within 30s |
| 8 | Loki API reachable | `kubectl port-forward svc/loki-gateway -n logging 3100:80` → `curl 'http://localhost:3100/loki/api/v1/labels'` |
| 9 | Logs in Grafana | Explore → Loki datasource → `{namespace="simple-time-service"}` |

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
│           ├── hpa.yaml
│           ├── pdb.yaml
│           ├── networkpolicy.yaml
│           ├── _helpers.tpl
│           └── NOTES.txt
├── gitops/
│   ├── bootstrap/
│   │   └── root-app.yaml                       # ArgoCD root Application - bootstraps everything below
│   ├── app/
│   │   └── simple-time-service.yaml            # ApplicationSet - Helm deploy to every registered cluster
│   ├── metrics-server/
│   │   └── metrics-server.yaml                 # ApplicationSet - metrics-server (HPA prerequisite)
│   ├── monitoring/
│   │   ├── prometheus/
│   │   │   └── prometheus.yaml                 # ApplicationSet - kube-prometheus-stack
│   │   └── grafana/
│   │       └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap
│   ├── alerts/
│   │   ├── simple-time-service-alerts.yaml     # ApplicationSet - PrometheusRule (alert expressions)
│   │   └── alertmanager-slack.yaml             # ApplicationSet - AlertmanagerConfig (Slack routing)
│   └── logs/
│       ├── loki/
│       │   ├── loki.yaml                       # ApplicationSet - Loki single-binary log store
│       │   └── grafana-loki-datasource.yaml    # ApplicationSet - Loki datasource ConfigMap for Grafana
│       └── fluent-bit/
│           └── fluent-bit.yaml                 # ApplicationSet - Fluent Bit DaemonSet (collector → Loki)
├── scripts/
│   ├── load_test.py                            # Python load generator (no dependencies)
│   └── k6-staged.js                            # k6 staged ramping-arrival-rate scenario
├── secrets/
│   └── alertmanager-config.example.yaml        # Slack webhook secret template (fill in and apply; gitignored)
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
    ├── bootstrap/                              # One-shot module - infra + Helm release in a single apply
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
        └── eks/                                # EKS - managed node group on private subnets
            ├── main.tf
            ├── variables.tf
            └── outputs.tf
```

---

## Design notes

These are intentional trade-offs for a demo environment:

- **Single NAT gateway** - reduces cost; use one per AZ in production for fault tolerance.
- **Public EKS API endpoint** - acceptable for demos; restrict `public_access_cidrs` in production.
- **No ingress controller** - the GitOps path uses `kubectl port-forward`; the bootstrap path exposes the service via an NLB-backed `LoadBalancer` service.
- **ArgoCD installed manually once** - everything it manages is then fully GitOps-driven.
- **Prometheus Operator TLS and webhooks disabled** - simplifies initial bootstrap reliability.
- **Loki on emptyDir** - logs are ephemeral by design; replace with S3/GCS for any persistent environment.
- **Network Policy disabled by default** - the chart includes a `NetworkPolicy` resource but it is off by default. Enabling it requires two steps: turning on the VPC CNI Network Policy controller in Terraform, then setting `networkPolicy.enabled: true` in the ArgoCD ApplicationSet. See [gitops/README.md](gitops/README.md#network-policy).

---

## Cleanup

```bash
# 1. Remove ArgoCD-managed apps (prune: true cascades to child resources)
kubectl delete -f gitops/bootstrap/root-app.yaml

# 2. Uninstall ArgoCD
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd

# 3. Destroy infrastructure
cd terraform && terraform destroy
# or, if you used bootstrap:
cd terraform/bootstrap && terraform destroy
```

> The S3 state bucket is not removed by `terraform destroy`. Delete it manually when no longer needed:
> ```bash
> aws s3 rb s3://<your-bucket-name> --force
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
| Slack alerts not arriving | Check secret: `kubectl get secret slack-webhook-url -n monitoring`. Check config: `kubectl describe alertmanagerconfig slack -n monitoring`. Confirm the `notify: slack` label is on the alert. |
| `alertmanager-slack` app degraded in ArgoCD | `slack-webhook-url` secret is missing. Apply it then `argocd app sync alertmanager-slack-simple-eks`. |
