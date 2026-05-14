# ArgoCD — Projects & Self-management

The `gitops/argocd/` directory owns two things: ArgoCD's own self-management and the AppProject definitions that govern every other app in the platform.

| File | What it deploys |
|------|----------------|
| `argocd.yaml` | ArgoCD self-management — keeps ArgoCD itself in sync via its own Helm chart (sync-wave none) |
| `argocd-ingress.yaml` | ALB Ingress for the ArgoCD UI at `argocd.platform.<domain>` (sync-wave 6) |
| `argocd-admin-secret.yaml` | ExternalSecret — syncs the ArgoCD admin password from AWS Secrets Manager (sync-wave 5) |
| `projects/` | AppProject definitions — one per domain (see below) |

---

## AppProjects

AppProjects are the primary security boundary in ArgoCD. Each project defines:
- Which Git repos apps may source from (`sourceRepos`)
- Which clusters/namespaces apps may deploy to (`destinations`)
- Which cluster-scoped resource kinds apps may manage (`clusterResourceWhitelist`)
- Which namespace-scoped resource kinds apps may manage (`namespaceResourceWhitelist`)

### Project overview

| Project | Purpose | Cluster access |
|---------|---------|----------------|
| `bootstrap` | Owns root-app only — the app-of-apps that bootstraps the entire GitOps hierarchy | None (`[]`) |
| `namespaces` | Cluster namespace lifecycle — creates namespaces and ResourceQuotas | `Namespace` only |
| `platform` | Cluster infrastructure — networking, autoscaling, secrets, storage, ArgoCD self-management | Wildcard (`*/*`) |
| `observability` | Observability stack — Prometheus, Grafana, Thanos, Loki, Fluent Bit | CRDs, ClusterRoles, webhooks, APIService |
| `security` | Policy enforcement — Kyverno admission controller and ClusterPolicy rules | CRDs, ClusterRoles/Bindings, webhooks, `ClusterPolicy` |
| `workloads` | Application workloads | None (`[]`) |

### Least-privilege design

Each project has exactly the permissions its apps need:

```
bootstrap     →  [] cluster access   (AppProjects + Applications only, namespace-scoped in argocd)
namespaces    →  Namespace           (creates namespaces + ResourceQuotas)
platform      →  */*                 (CRDs, ClusterRoles, webhooks — infra tools need broad access)
observability →  explicit list       (CRDs, ClusterRoles, webhooks, APIService for Prometheus stack)
security      →  explicit list       (CRDs, ClusterRoles, webhooks, ClusterPolicy — Kyverno needs all four)
workloads     →  [] cluster access   (Deployments, Services, etc. — all namespace-scoped)
```

The `workloads` project's `namespaceResourceWhitelist` is an explicit allowlist of namespace-scoped kinds workload charts are permitted to create, preventing a compromised workload from creating arbitrary resources (e.g. ClusterRoleBindings via a rogue Helm chart).

---

## The argocd namespace bootstrap boundary

The `argocd` namespace is the one namespace that cannot be managed by the `cluster-namespaces` GitOps app. The reason is circular:

```
cluster-namespaces runs inside ArgoCD
        ↓
ArgoCD lives in the argocd namespace
        ↓
argocd namespace must exist before ArgoCD starts
        ↓
cannot be created by a GitOps app
```

The `argocd` namespace is created by `helm install --create-namespace` in `bootstrap.sh` — before any GitOps reconciliation begins. This is the only namespace that is not managed via Git.

`CreateNamespace=true` on `root-app` and `argocd.yaml` is a no-op safety net (the namespace already exists), not the actual creation mechanism.

`kube-system` and `kube-node-lease` are Kubernetes built-ins and are never managed by this platform.

---

## Sync wave ordering

Root-app discovers all YAML files under `gitops/` recursively. Sync wave annotations on each ApplicationSet control the order in which root-app creates them:

| Wave | What syncs |
|------|-----------|
| -1 | `cluster-namespaces` — all cluster namespaces created before anything deploys into them |
| 0 | `prometheus-crds` — CRDs installed before the Prometheus stack |
| 1 | Storage, autoscaling baseline, secrets operator, reloader |
| 2 | Networking (ALB controller, ExternalDNS) |
| 3 | Karpenter, Velero, Kyverno |
| 4 | Karpenter node pools, cluster secret store |
| 5 | Secrets (ArgoCD admin, Grafana admin, Alertmanager webhook, Thanos objstore), Kyverno ClusterPolicies |
| 6 | Loki, ArgoCD ingress, Policy Reporter UI |
| 7 | Prometheus |
| 8 | Workloads, Grafana dashboards, Fluent Bit |
| 9 | Prometheus Adapter, Alertmanager Slack |
| 10 | Thanos, alert rules |
