# GitOps Platform

Implements the **App of Apps** pattern with ArgoCD. A single root Application bootstraps ArgoCD, which then discovers and reconciles every platform component declared in this directory.

![ArgoCD Applications](../docs/images/ArgoCD%20UI.png)

---

## Directory structure

```
gitops/
├── bootstrap/
│   └── root-app.yaml                       # Root Application - bootstraps everything below
├── app/
│   └── simple-time-service.yaml            # ApplicationSet - Helm deploy to every registered cluster
├── metrics-server/
│   └── metrics-server.yaml                 # ApplicationSet - metrics-server (HPA prerequisite)
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yaml                 # ApplicationSet - kube-prometheus-stack
│   └── grafana/
│       └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap
├── alerts/
│   ├── simple-time-service-alerts.yaml     # ApplicationSet - PrometheusRule (alert expressions)
│   └── alertmanager-slack.yaml             # ApplicationSet - AlertmanagerConfig (Slack routing)
└── logs/
    ├── loki/
    │   ├── loki.yaml                        # ApplicationSet - Loki single-binary log store
    │   └── grafana-loki-datasource.yaml     # ApplicationSet - Loki datasource ConfigMap for Grafana
    └── fluent-bit/
        └── fluent-bit.yaml                  # ApplicationSet - Fluent Bit DaemonSet (collector → Loki)
```

---

## Sub-READMEs

| | |
|-|-|
| [monitoring/README.md](monitoring/README.md) | Prometheus, Grafana dashboard, ServiceMonitor verification |
| [alerts/README.md](alerts/README.md) | PrometheusRules, Slack setup, testing, silencing, grouping |
| [logs/README.md](logs/README.md) | Loki, Fluent Bit, Grafana datasource, LogQL queries |

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` configured against the EKS cluster | Deploy and manage ArgoCD |
| `argocd` CLI (optional) | Interact with ArgoCD from the terminal |

---

## Installing ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd
```

Retrieve the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## Bootstrap

Apply the root app once - this is the only manual step:

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

ArgoCD reconciles the `gitops/` directory. Within the default polling interval (up to 3 minutes) it discovers all ApplicationSets and provisions every platform component.

---

## Accessing the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080). Log in with `admin` and the password retrieved above.

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
| simple-time-service | simple-time-service | — | SimpleTimeService Helm chart (HPA enabled) |
| metrics-server | kube-system | — | CPU/memory metrics for HPA |
| prometheus | monitoring | — | kube-prometheus-stack |
| grafana-dashboard | monitoring | 2 | SimpleTimeService dashboard ConfigMap |
| simple-time-service-alerts | monitoring | — | PrometheusRule CRD |
| alertmanager-slack | monitoring | — | AlertmanagerConfig CRD |
| loki | logging | 3 | Loki log store |
| fluent-bit | logging | 4 | Log collector DaemonSet |
| grafana-loki-datasource | monitoring | 4 | Loki datasource ConfigMap |

---

## Autoscaling - HPA and metrics-server

`metrics-server` is a hard prerequisite for HPA - without it the HPA controller cannot read pod utilization and no scaling decisions are made. Two flags are set for EKS compatibility:

| Flag | Reason |
|------|--------|
| `--kubelet-preferred-address-types=InternalIP` | EKS node hostnames are not resolvable inside the cluster |
| `--kubelet-insecure-tls` | Skips kubelet TLS verification (acceptable for demos) |

The HPA is **disabled by default** in the chart's `values.yaml` and enabled via an override in `gitops/app/simple-time-service.yaml`:

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

**Step 2 - enable the NetworkPolicy resource** in `gitops/app/simple-time-service.yaml`:

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
