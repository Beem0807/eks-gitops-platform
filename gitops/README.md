# GitOps Platform

Implements the **App of Apps** pattern with ArgoCD. A single root Application bootstraps ArgoCD, which then discovers and reconciles every platform component declared in this directory.

![ArgoCD Applications](../docs/images/ArgoCD%20UI.png)

---

## Directory structure

```
gitops/
├── bootstrap/
│   └── root-app.yaml                           # Root Application - bootstraps everything below
├── argocd/
│   ├── argocd.yaml                             # Application - ArgoCD self-managed via Helm
│   ├── argocd-admin-secret.yaml                # ApplicationSet - ExternalSecret for ArgoCD admin password
│   └── argocd-ingress.yaml                     # ApplicationSet - ALB Ingress at argocd.platform.<domain>
├── app/
│   └── simple-time-service/
│       └── simple-time-service.yaml            # ApplicationSet - Helm deploy with ALB Ingress
├── auto-scaling/
│   ├── cluster-autoscaler/
│   │   └── cluster-autoscaler.yaml             # ApplicationSet - Cluster Autoscaler (wave 1)
│   ├── karpenter/
│   │   ├── karpenter.yaml                      # ApplicationSet - Karpenter controller (wave 2)
│   │   └── karpenter-nodepools.yaml            # ApplicationSet - EC2NodeClass + NodePool (wave 3)
│   └── metrics-server/
│       └── metrics-server.yaml                 # ApplicationSet - metrics-server (HPA prerequisite)
├── networking/
│   ├── ingress-controller/
│   │   └── aws-load-balancer-controller.yaml   # ApplicationSet - AWS Load Balancer Controller (wave 1)
│   └── external-dns/
│       └── external-dns.yaml                   # ApplicationSet - ExternalDNS for Route53 (wave 1)
├── secrets/
│   ├── external-secrets/
│   │   ├── external-secret-operator.yaml       # ApplicationSet - External Secrets Operator (wave 1)
│   │   └── cluster-secret-store.yaml           # ApplicationSet - ClusterSecretStore (wave 2)
│   └── reloader/
│       └── reloader.yaml                       # ApplicationSet - Stakater Reloader (wave 1)
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus-crds.yaml                # ApplicationSet - Prometheus Operator CRDs (wave 0)
│   │   ├── prometheus.yaml                     # ApplicationSet - kube-prometheus-stack (wave 4)
│   │   └── prometheus-adapter.yaml             # ApplicationSet - custom metrics API bridge (wave 5)
│   ├── thanos/
│   │   ├── thanos-objstore-secret.yaml         # ApplicationSet - S3 objstore Secret (wave 3)
│   │   └── thanos.yaml                         # ApplicationSet - Thanos query/compactor/storegateway (wave 6)
│   └── grafana/
│       ├── grafana-admin-secret.yaml           # ApplicationSet - ExternalSecret for Grafana credentials
│       └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap (wave 2)
├── alerts/
│   ├── simple-time-service-alerts.yaml         # ApplicationSet - PrometheusRule (alert expressions)
│   ├── alertmanager-webhook-secret.yaml        # ApplicationSet - ExternalSecret for Slack webhook
│   └── alertmanager-slack.yaml                 # ApplicationSet - AlertmanagerConfig (Slack routing)
└── logs/
    ├── loki/
    │   ├── loki.yaml                            # ApplicationSet - Loki single-binary log store (wave 3)
    │   └── grafana-loki-datasource.yaml         # ApplicationSet - Loki datasource ConfigMap (wave 4)
    └── fluent-bit/
        └── fluent-bit.yaml                      # ApplicationSet - Fluent Bit DaemonSet (wave 4)
```

---

## Sub-READMEs

| | |
|-|-|
| [auto-scaling/README.md](auto-scaling/README.md) | Cluster Autoscaler, Karpenter, NodePool config, metrics-server, HPA |
| [networking/README.md](networking/README.md) | AWS Load Balancer Controller, ExternalDNS, Ingress annotations |
| [secrets/README.md](secrets/README.md) | External Secrets Operator, ClusterSecretStore, ExternalSecret mappings, Reloader |
| [monitoring/README.md](monitoring/README.md) | Prometheus, Grafana, Thanos, Prometheus Adapter, ServiceMonitor |
| [alerts/README.md](alerts/README.md) | PrometheusRules, Slack setup, testing, silencing, grouping |
| [logs/README.md](logs/README.md) | Loki, Fluent Bit, Grafana datasource, LogQL queries |

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` configured against the EKS cluster | Deploy and manage ArgoCD |
| `argocd` CLI (optional) | Interact with ArgoCD from the terminal |

---

## Installing ArgoCD and bootstrapping

ArgoCD is installed via Helm and self-managed as a GitOps app after initial bootstrap. The full process is handled by `terraform/scripts/bootstrap.sh`:

```bash
export TF_VAR_alertmanager_slack_webhook_url="https://hooks.slack.com/..."
bash terraform/scripts/bootstrap.sh
```

The script installs ArgoCD using the official Helm chart (`argo-cd` v9.4.17) and then applies the root app. ArgoCD takes over and manages its own Helm release from that point on via `gitops/argocd/argocd.yaml`.

Retrieve the admin password (set by the bootstrap script and stored in AWS Secrets Manager):

```bash
aws secretsmanager get-secret-value --secret-id argocd-admin \
  --query SecretString --output text | jq -r '.adminPassword'
```

---

## Accessing the ArgoCD UI

ArgoCD is exposed via ALB Ingress at `https://argocd.platform.<your-domain>`.

Or use port-forward if DNS is not yet available:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open [http://localhost:8080](http://localhost:8080).

---

## Syncing via CLI

```bash
argocd login localhost:8080 --username admin --password <password> --insecure

argocd app sync root-app
argocd app get simple-time-service-in-cluster
```

---

## Sync policy

The root Application uses **automated sync with pruning and self-healing**:

```yaml
syncPolicy:
  automated:
    prune: true      # delete resources removed from Git
    selfHeal: true   # revert manual changes made directly in the cluster
```

Any push to `main` affecting `gitops/` or `charts/` is automatically applied within the ArgoCD polling interval (3 minutes). Manual syncs via the UI or CLI take effect immediately.

---

## Application inventory

| App | Namespace | Sync wave | Purpose |
|-----|-----------|-----------|---------|
| root-app | argocd | — | Discovers all other apps |
| argocd-self | argocd | — | ArgoCD self-managed via Helm |
| argocd-admin-secret | argocd | 3 | Syncs ArgoCD admin password from Secrets Manager |
| argocd-ingress | argocd | 2 | ALB Ingress at `argocd.platform.<domain>` |
| external-secrets | external-secrets | 1 | External Secrets Operator |
| cluster-secret-store | external-secrets | 2 | ClusterSecretStore pointing to AWS Secrets Manager |
| reloader | reloader | 1 | Stakater Reloader (watches Secrets/ConfigMaps) |
| aws-load-balancer-controller | kube-system | 1 | ALB Ingress controller |
| external-dns | external-dns | 1 | Route53 DNS records from Ingress/Service |
| cluster-autoscaler | kube-system | 1 | Scales managed node group on pending pods |
| karpenter | karpenter | 2 | Karpenter controller (workload node provisioner) |
| karpenter-nodepools | karpenter | 3 | EC2NodeClass + NodePool for `t3a.medium`/`c6a.large` |
| metrics-server | kube-system | — | CPU/memory metrics for HPA |
| prometheus-crds | monitoring | 0 | Prometheus Operator CRDs (pre-installed before stack) |
| prometheus | monitoring | 4 | kube-prometheus-stack |
| prometheus-adapter | monitoring | 5 | Custom metrics API bridge (enables custom-metric HPA) |
| thanos-objstore-secret | monitoring | 3 | S3 objstore Secret injected from cluster annotations |
| thanos | monitoring | 6 | Thanos Query, Compactor, StoreGateway |
| grafana-admin-secret | monitoring | 3 | Syncs Grafana admin credentials from Secrets Manager |
| grafana-dashboard | monitoring | 2 | SimpleTimeService dashboard ConfigMap |
| simple-time-service-alerts | monitoring | 5 | PrometheusRule CRD |
| alertmanager-webhook-secret | monitoring | 3 | Syncs Slack webhook URL from Secrets Manager |
| alertmanager-slack | monitoring | 4 | AlertmanagerConfig CRD |
| loki | logging | 3 | Loki log store |
| fluent-bit | logging | 4 | Log collector DaemonSet |
| grafana-loki-datasource | monitoring | 4 | Loki datasource ConfigMap |
| simple-time-service | simple-time-service | 4 | SimpleTimeService Helm chart (HPA, ALB Ingress) |

---

## Autoscaling

### Node architecture: core vs workload nodes

The managed node group runs system components with the `app=core` node label and `app=core:NoSchedule` taint. All platform workloads (ArgoCD, Prometheus, networking controllers) tolerate this taint and run exclusively on core nodes.

Karpenter provisions a separate pool of workload nodes (labeled `app=workload`, tainted `app=workload:NoSchedule`) for the application. The `simple-time-service` Deployment is configured with `nodeSelector: {app: workload}` and the matching toleration, so it only lands on Karpenter-provisioned nodes.

Workload NodePool: `t3a.medium` or `c6a.large` (on-demand), AMI `al2023`, consolidation enabled (`WhenEmptyOrUnderutilized`, 5m delay), node expiry 30 days.

### Cluster Autoscaler

Scales the core managed node group based on pending pods. Configured with IRSA (`arn:aws:iam::<account>/simple-eks-cluster-autoscaler-irsa`) and auto-discovery via the `k8s.io/cluster-autoscaler/simple-eks` tag.

### HPA and metrics-server

`metrics-server` is a hard prerequisite for HPA - without it the HPA controller cannot read pod utilization and no scaling decisions are made. Two flags are set for EKS compatibility:

| Flag | Reason |
|------|--------|
| `--kubelet-preferred-address-types=InternalIP` | EKS node hostnames are not resolvable inside the cluster |
| `--kubelet-insecure-tls` | Skips kubelet TLS verification (acceptable for demos) |

The HPA is **disabled by default** in the chart's `values.yaml` and enabled via an override in `gitops/app/simple-time-service/simple-time-service.yaml`:

```yaml
hpa:
  enabled: true
```

When enabled, it targets 70% average CPU and scales between 2 and 10 replicas. Scale-up is fast (2 pods per 30s, no delay); scale-down is conservative (1 pod per minute, 5-minute stabilization window) to avoid thrashing.

```bash
kubectl get hpa -n simple-time-service
kubectl top pods -n simple-time-service
```

---

## Network Policy

Disabled by default. Enabling it requires two steps.

**Step 1 - enable the VPC CNI Network Policy controller** in [terraform/modules/eks/main.tf](../terraform/modules/eks/main.tf):

```hcl
vpc-cni = {
  before_compute = true
  most_recent    = true
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}
```

Then apply: `cd terraform && terraform apply`

**Step 2 - enable the NetworkPolicy resource** in `gitops/app/simple-time-service/simple-time-service.yaml`:

```yaml
helm:
  values: |
    networkPolicy:
      enabled: true
```

Push to `main`. ArgoCD deploys the policy within 3 minutes.

| Direction | Allowed | Reason |
|-----------|---------|--------|
| Ingress | Port 8080 from same namespace | Pod-to-pod traffic |
| Ingress | Port 8080 from `monitoring` namespace | Prometheus scraping |
| Egress | Port 53 UDP/TCP | DNS resolution |
| Everything else | Denied | App makes no outbound calls |

```bash
kubectl get networkpolicy -n simple-time-service
```
