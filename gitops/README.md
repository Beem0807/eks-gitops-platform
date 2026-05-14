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
│   ├── projects/
│   │   ├── bootstrap-project.yaml              # AppProject - owns root-app only, minimal scope
│   │   ├── namespaces-project.yaml             # AppProject - cluster namespace lifecycle
│   │   ├── platform-project.yaml               # AppProject - ArgoCD, infra, networking, secrets
│   │   ├── observability-project.yaml          # AppProject - monitoring, logging, alerting
│   │   └── workloads-project.yaml              # AppProject - application workloads
│   ├── argocd.yaml                             # Application - ArgoCD self-managed via Helm
│   ├── argocd-admin-secret.yaml                # ApplicationSet - ExternalSecret for ArgoCD admin password (wave 5)
│   └── argocd-ingress.yaml                     # ApplicationSet - ALB Ingress at argocd.platform.<domain> (wave 6)
├── namespaces/
│   └── cluster-namespaces.yaml                 # ApplicationSet - creates all cluster namespaces (wave -1)
├── app/
│   └── simple-time-service/
│       └── simple-time-service.yaml            # ApplicationSet - Helm deploy with ALB Ingress (wave 8)
├── auto-scaling/
│   ├── cluster-autoscaler/
│   │   └── cluster-autoscaler.yaml             # ApplicationSet - Cluster Autoscaler (wave 1)
│   ├── karpenter/
│   │   ├── karpenter.yaml                      # ApplicationSet - Karpenter controller (wave 3)
│   │   └── karpenter-nodepools.yaml            # ApplicationSet - EC2NodeClass + NodePool (wave 4)
│   └── metrics-server/
│       └── metrics-server.yaml                 # ApplicationSet - metrics-server (HPA prerequisite)
├── networking/
│   ├── ingress-controller/
│   │   └── aws-load-balancer-controller.yaml   # ApplicationSet - AWS Load Balancer Controller (wave 2)
│   └── external-dns/
│       └── external-dns.yaml                   # ApplicationSet - ExternalDNS for Route53 (wave 2)
├── storage/
│   ├── README.md
│   └── ebs-csi-driver/
│       └── ebs-csi-driver.yaml                 # ApplicationSet - AWS EBS CSI Driver (wave 1)

├── backup/
│   ├── README.md
│   └── velero/
│       ├── velero.yaml                         # ApplicationSet - Velero backup and restore (wave 3)
│       └── velero-schedule.yaml                # ApplicationSet - daily full-cluster backup Schedule (wave 5)
├── secrets/
│   ├── external-secrets/
│   │   ├── external-secret-operator.yaml       # ApplicationSet - External Secrets Operator (wave 1)
│   │   └── cluster-secret-store.yaml           # ApplicationSet - ClusterSecretStore (wave 4)
│   └── reloader/
│       └── reloader.yaml                       # ApplicationSet - Stakater Reloader (wave 1)
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus-crds.yaml                # ApplicationSet - Prometheus Operator CRDs (wave 0)
│   │   ├── prometheus.yaml                     # ApplicationSet - kube-prometheus-stack (wave 7)
│   │   └── prometheus-adapter.yaml             # ApplicationSet - custom metrics API bridge (wave 9)
│   ├── thanos/
│   │   ├── thanos-objstore-secret.yaml         # ApplicationSet - S3 objstore Secret (wave 5)
│   │   └── thanos.yaml                         # ApplicationSet - Thanos query/compactor/storegateway (wave 10)
│   └── grafana/
│       ├── grafana-admin-secret.yaml           # ApplicationSet - ExternalSecret for Grafana credentials (wave 5)
│       └── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap (wave 8)
├── alerts/
│   ├── simple-time-service-alerts.yaml         # ApplicationSet - PrometheusRule (alert expressions) (wave 10)
│   ├── alertmanager-webhook-secret.yaml        # ApplicationSet - ExternalSecret for Slack webhook (wave 5)
│   └── alertmanager-slack.yaml                 # ApplicationSet - AlertmanagerConfig (Slack routing) (wave 9)
└── logs/
    ├── loki/
    │   ├── loki.yaml                            # ApplicationSet - Loki single-binary log store (wave 6)
    │   └── grafana-loki-datasource.yaml         # ApplicationSet - Loki datasource ConfigMap (wave 8)
    └── fluent-bit/
        └── fluent-bit.yaml                      # ApplicationSet - Fluent Bit DaemonSet (wave 8)
└── security/
    └── kyverno/
        ├── kyverno.yaml                            # ApplicationSet - Kyverno admission controller (wave 3)
        ├── kyverno-policies.yaml                   # ApplicationSet - ClusterPolicy rules via charts/raw (wave 5)
        ├── policy-reporter-secret.yaml             # ApplicationSet - ExternalSecret for basic auth (wave 5)
        └── policy-reporter.yaml                    # ApplicationSet - Policy Reporter UI with ALB Ingress (wave 6)
```

---

## Sub-READMEs

| | |
|-|-|
| [auto-scaling/README.md](auto-scaling/README.md) | Cluster Autoscaler, Karpenter, NodePool config, metrics-server, HPA |
| [networking/README.md](networking/README.md) | AWS Load Balancer Controller, ExternalDNS, Ingress annotations |
| [secrets/README.md](secrets/README.md) | External Secrets Operator, ClusterSecretStore, ExternalSecret mappings, Reloader |
| [storage/README.md](storage/README.md) | EBS CSI Driver, gp3 StorageClass, PVC inventory |
| [backup/README.md](backup/README.md) | Velero, S3 backup location, EBS snapshots, backup and restore commands |
| [monitoring/README.md](monitoring/README.md) | Prometheus, Grafana, Thanos, Prometheus Adapter, ServiceMonitor |
| [alerts/README.md](alerts/README.md) | PrometheusRules, Slack setup, testing, silencing, grouping |
| [logs/README.md](logs/README.md) | Loki S3 backend, Fluent Bit, Grafana datasource, LogQL queries |
| [security/README.md](security/README.md) | Kyverno policies, Policy Reporter UI, basic auth, policy reports |

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

The script installs ArgoCD using the official Helm chart (`argo-cd` v9.4.17), applies all AppProjects from `gitops/argocd/projects/`, and then applies the root app. ArgoCD takes over and manages its own Helm release from that point on via `gitops/argocd/argocd.yaml`. Any future project changes pushed to `main` are automatically reconciled by the root app (it recurses the entire `gitops/` directory).

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

| App | Namespace | Project | Sync wave | Purpose |
|-----|-----------|---------|-----------|---------|
| root-app | argocd | bootstrap | — | Discovers all other apps |
| argocd-self | argocd | platform | — | ArgoCD self-managed via Helm |
| cluster-namespaces | — | namespaces | -1 | Creates all cluster namespaces before any app deploys |
| prometheus-crds | monitoring | observability | 0 | Prometheus Operator CRDs (pre-installed before stack) |
| external-secrets | external-secrets | platform | 1 | External Secrets Operator |
| aws-ebs-csi-driver | kube-system | platform | 1 | EBS volumes + `gp3` default StorageClass |
| reloader | reloader | platform | 1 | Stakater Reloader (watches Secrets/ConfigMaps) |
| cluster-autoscaler | kube-system | platform | 1 | Scales managed node group on pending pods |
| aws-load-balancer-controller | kube-system | platform | 2 | ALB Ingress controller (webhook cert propagates before wave 6 Ingresses) |
| external-dns | external-dns | platform | 2 | Route53 DNS records from Ingress/Service |
| karpenter | karpenter | platform | 3 | Karpenter controller (workload node provisioner) |
| velero | velero | platform | 3 | Cluster backup and restore to S3 + EBS snapshots |
| kyverno | security | security | 3 | Kyverno admission controller — enforces ClusterPolicies cluster-wide |
| cluster-secret-store | external-secrets | platform | 4 | ClusterSecretStore pointing to AWS Secrets Manager |
| karpenter-nodepools | karpenter | platform | 4 | EC2NodeClass + NodePool for `t3a.medium`/`c6a.large` |
| kyverno-policies | security | security | 5 | Four audit-mode ClusterPolicies (resource limits, privileged containers, latest tag, non-root) |
| argocd-admin-secret | argocd | platform | 5 | Syncs ArgoCD admin password from Secrets Manager |
| grafana-admin-secret | monitoring | observability | 5 | Syncs Grafana admin credentials from Secrets Manager |
| alertmanager-webhook-secret | monitoring | observability | 5 | Syncs Slack webhook URL from Secrets Manager |
| thanos-objstore-secret | monitoring | observability | 5 | S3 objstore Secret injected from cluster annotations |
| velero-schedule | velero | platform | 5 | Daily full-cluster backup at 02:00 UTC, 30-day retention |
| policy-reporter-secret | security | security | 5 | Syncs Policy Reporter basic auth credentials from Secrets Manager |
| argocd-ingress | argocd | platform | 6 | ALB Ingress at `argocd.platform.<domain>` |
| policy-reporter | security | security | 6 | Policy Reporter UI at `policy-reporter.platform.<domain>` |
| loki | logging | observability | 6 | Loki log store |
| prometheus | monitoring | observability | 7 | kube-prometheus-stack |
| simple-time-service | simple-time-service | workloads | 8 | SimpleTimeService Helm chart (HPA, ALB Ingress) |
| fluent-bit | logging | observability | 8 | Log collector DaemonSet |
| grafana-loki-datasource | monitoring | observability | 8 | Loki datasource ConfigMap |
| grafana-dashboard | monitoring | observability | 8 | SimpleTimeService dashboard ConfigMap |
| prometheus-adapter | monitoring | observability | 9 | Custom metrics API bridge (enables custom-metric HPA) |
| alertmanager-slack | monitoring | observability | 9 | AlertmanagerConfig CRD |
| simple-time-service-alerts | monitoring | observability | 10 | PrometheusRule CRD |
| thanos | monitoring | observability | 10 | Thanos Query, Compactor, StoreGateway |
| metrics-server | kube-system | platform | — | CPU/memory metrics for HPA |

---

## Sync wave strategy

ArgoCD advances through sync waves sequentially, waiting for all resources in the current wave to be healthy before starting the next. The wave ordering is designed to eliminate race conditions caused by admission webhook cert propagation and operator readiness.

| Wave | Components | Why this boundary |
|------|-----------|-------------------|
| -1 | **cluster-namespaces** | All namespaces created before any app attempts to deploy into them |
| 0 | Prometheus CRDs | CRDs must exist before any resource of those types is applied |
| 1 | ESO, EBS CSI, Reloader, Cluster Autoscaler | Core infrastructure with no cross-dependencies |
| 2 | **LBC**, ExternalDNS | Network controllers given their own wave so the LBC admission webhook cert has time to propagate before any Ingress is applied |
| 3 | Karpenter, Velero, **Kyverno** | All three install admission webhooks; a one-wave gap after LBC lets all webhook cert chains stabilise |
| 4 | ClusterSecretStore, Karpenter NodePools | Require wave 1 (ESO) and wave 3 (Karpenter) webhook certs to be stable |
| 5 | All ExternalSecrets, VeleroSchedule, Kyverno ClusterPolicies, policy-reporter-secret | Require ClusterSecretStore (wave 4) to be ready before they can sync from Secrets Manager |
| 6 | **ArgoCD Ingress**, Loki, Policy Reporter UI | Ingresses applied 4 waves after LBC — webhook cert fully propagated |
| 7 | Prometheus (kube-prometheus-stack) | Requires secrets (wave 5) and LBC for Grafana Ingress (wave 2 mature) |
| 8 | SimpleTimeService, Fluent Bit, Grafana datasource + dashboard | Require Loki (wave 6) and Prometheus (wave 7) |
| 9 | Prometheus Adapter, AlertmanagerConfig | Require Prometheus to be running |
| 10 | PrometheusRules, Thanos | Require Prometheus with Thanos sidecar healthy |

> **Note:** The `loki`, `fluent-bit`, `grafana-loki-datasource`, and `simple-time-service-alerts` ApplicationSets previously had their sync-wave annotation only on the inner Application template rather than on the ApplicationSet itself, meaning root-app treated them as wave 0. The annotation is now correctly placed on `metadata.annotations` of each ApplicationSet.

---

## ArgoCD Projects

All ApplicationSets are scoped to one of five AppProjects defined in `gitops/argocd/projects/`. Projects enforce which source repos, destination namespaces, and cluster-scoped resource kinds each group of apps is allowed to use — preventing a misconfigured or compromised app from deploying to an unintended namespace or installing arbitrary cluster resources.

| Project | File | Allowed namespaces | Cluster resources | Covers |
|---------|------|--------------------|-------------------|--------|
| `bootstrap` | `bootstrap-project.yaml` | `argocd` | None — root-app only deploys namespace-scoped ArgoCD resources | root-app only |
| `namespaces` | `namespaces-project.yaml` | `*` | `Namespace` only | cluster-namespaces (creates namespaces + ResourceQuotas) |
| `platform` | `platform-project.yaml` | `argocd`, `kube-system`, `karpenter`, `external-secrets`, `external-dns`, `reloader`, `velero`, `kube-node-lease` | All (`*/*`) — infra tools install CRDs and cluster RBAC | ArgoCD self-management, networking, autoscaling, secrets, storage, backup |
| `observability` | `observability-project.yaml` | `monitoring`, `logging`, `kube-system` | `CustomResourceDefinition`, `ClusterRole`, `ClusterRoleBinding` | Prometheus, Grafana, Thanos, Loki, Fluent Bit, alerts |
| `security` | `security-project.yaml` | `security` | `CustomResourceDefinition`, `ClusterRole`, `ClusterRoleBinding`, webhooks, `ClusterPolicy` | Kyverno admission controller, ClusterPolicies, Policy Reporter |
| `workloads` | `workloads-project.yaml` | `simple-time-service` | None | Application workloads |

The `bootstrap` project breaks the circular dependency that existed when root-app lived in the `platform` project: root-app managed the platform AppProject, but the platform AppProject governed root-app's permissions. If the platform project became misconfigured, root-app could not reconcile itself out of the problem. With root-app in its own tightly-scoped project, a broken platform project does not affect root-app — and recovering is a single `kubectl apply`.

**Bootstrap order:** `bootstrap.sh` applies all project manifests from `gitops/argocd/projects/` (including `bootstrap-project.yaml`) before applying `root-app.yaml`, ensuring every project exists before ArgoCD tries to sync an app that references it. After bootstrap, project changes pushed to `main` are automatically reconciled by root-app via `ServerSideApply`.

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
