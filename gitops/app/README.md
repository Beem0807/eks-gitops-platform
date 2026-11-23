# Application workloads

Everything the platform deploys for a single application lives in that
application's directory - the workload itself and the observability resources
that describe it.

```
app/
└── simple-time-service/
    ├── simple-time-service.yaml            # ApplicationSet - Helm deploy, ALB Ingress, HPA (wave 8)
    ├── simple-time-service-dashboard.yaml  # ApplicationSet - Grafana dashboard ConfigMap (wave 8)
    └── simple-time-service-alerts.yaml     # ApplicationSet - PrometheusRule (wave 10)
```

Grouping by **application** rather than by resource type means the full
surface of an app is one directory listing. Changing an alert threshold, adding
a dashboard panel, and bumping the image tag are one review in one place, and
deleting an application does not leave an orphaned `PrometheusRule` behind in
`alerts/` for someone to find later.

The `ServiceMonitor` is the exception, and deliberately so: it is a template in
[charts/simple-time-service](../../charts/simple-time-service/) and toggled with
`serviceMonitor.enabled`. It belongs to the chart because it selects the
chart's own Service by label - shipping it separately would mean duplicating
those selectors and keeping them in sync by hand.

---

## Directory grouping is not project scoping

The three ApplicationSets sit side by side but are **not** in the same ArgoCD
AppProject, because they do not deploy to the same namespace:

| ApplicationSet | Project | Namespace | Why |
|----------------|---------|-----------|-----|
| `simple-time-service` | `workloads` | `simple-time-service` | The app's own namespace; the `workloads` project permits nothing else |
| `grafana-dashboards` | `observability` | `monitoring` | Grafana's sidecar only imports dashboard ConfigMaps from the monitoring namespace |
| `simple-time-service-alerts` | `observability` | `monitoring` | Evaluated by the Prometheus instance in `monitoring` |

The `workloads` project is restricted to the `simple-time-service` namespace, so
moving the dashboard and alerts into it would break them. Project membership
follows the **destination namespace**; the directory follows the **application**.
These are independent, and this move changed only the second.

Nothing about what gets deployed changed when these files moved. The root app
recurses `gitops/` in full, and ArgoCD identifies an Application by its name -
not by the path of the file that declares it - so the names, projects,
destinations, and sync waves above are all exactly as they were.

---

## Sync wave ordering

| Wave | Resource | Depends on |
|------|----------|------------|
| 8 | Deployment, Service, Ingress, HPA, ServiceMonitor | Prometheus (7) for the ServiceMonitor CRD; LBC (2) for the Ingress |
| 8 | Grafana dashboard ConfigMap | Grafana, installed with Prometheus (7) |
| 10 | `PrometheusRule` | Prometheus Operator CRDs (0) and a running Prometheus (7) |

Alerts are last because a `PrometheusRule` that references a metric no pod is
producing yet fires immediately on a fresh cluster.

---

## Adding another application

1. Create `gitops/app/<name>/` and put the workload ApplicationSet in it.
2. Add `<name>` to the namespace list in
   [gitops/namespaces/namespaces.yaml](../namespaces/namespaces.yaml) - the
   platform owns namespace creation, in wave -1.
3. Add the namespace to `destinations` in
   [workloads-project.yaml](../argocd/projects/workloads-project.yaml). The
   `workloads` project is an explicit allowlist; without this the Application
   fails with `destination is not permitted`.
4. Put its dashboard and alerts in the same directory, keeping them in the
   `observability` project with `monitoring` as the destination.
