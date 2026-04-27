# Monitoring - Prometheus, Grafana, Thanos

The `gitops/monitoring/` directory deploys the full observability stack via ArgoCD.

| File | What it deploys |
|------|----------------|
| `prometheus/prometheus-crds.yaml` | Prometheus Operator CRDs only (sync-wave 0) - managed separately to allow safe CRD upgrades |
| `prometheus/prometheus.yaml` | `kube-prometheus-stack` (v82.18.0) - Prometheus, Grafana, Alertmanager, Prometheus Operator, ALB Ingress for all three UIs (sync-wave 4) |
| `prometheus/prometheus-adapter.yaml` | Prometheus Adapter - exposes Prometheus metrics via the Kubernetes custom metrics API (sync-wave 5) |
| `thanos/thanos-objstore-secret.yaml` | `thanos-objstore-config` Secret - S3 bucket name and region injected from the ArgoCD cluster secret annotations (sync-wave 3) |
| `thanos/thanos.yaml` | Thanos - Query, Compactor, StoreGateway (sync-wave 6) |
| `grafana/grafana-admin-secret.yaml` | ExternalSecret - syncs Grafana admin credentials from AWS Secrets Manager |
| `grafana/simple-time-service-dashboard.yaml` | Pre-built Grafana dashboard for SimpleTimeService via `charts/raw` |

---

## What gets deployed

| Component | Details |
|-----------|---------|
| Prometheus | Metrics collection, 7-day local retention, Thanos sidecar ships blocks to S3, ALB Ingress at `prometheus.platform.<domain>` (basic auth) |
| Grafana | Dashboards UI, ALB Ingress at `grafana.platform.<domain>`, auto-provisioned datasources |
| Alertmanager | Alert routing and grouping, ALB Ingress at `alertmanager.platform.<domain>` (basic auth) |
| Prometheus Operator | Manages `PrometheusRule` and `ServiceMonitor` CRDs |
| Prometheus Adapter | Custom metrics API (`/apis/custom.metrics.k8s.io`) - enables HPA on arbitrary Prometheus queries |
| Thanos Query | Unified query endpoint across Prometheus and S3-backed historical data |
| Thanos Compactor | Downsamples and enforces retention: 30d raw / 90d 5m / 180d 1h |
| Thanos StoreGateway | Serves historical blocks from S3 to Thanos Query |
| kube-state-metrics | Kubernetes object/state metrics (Deployments, Pods, resource requests) |

All components land in the `monitoring` namespace, created automatically by ArgoCD via `CreateNamespace=true`.

Grafana, Prometheus, and Alertmanager share the same ALB Ingress group (`platform-observability`) to minimize load balancers provisioned.

---

## Key configuration

`serviceMonitorSelectorNilUsesHelmValues: false` - tells Prometheus to discover `ServiceMonitor` resources across **all namespaces**. Without this, the `ServiceMonitor` in the `simple-time-service` namespace is silently ignored.

Prometheus Operator TLS and admission webhooks are disabled to simplify bootstrap. Enable them in production.

`KubeSchedulerDown` and `KubeControllerManagerDown` alerts are suppressed - on EKS the control plane is managed by AWS and never exposed for scraping, so these would fire permanently.

---

## Accessing Grafana

Open `https://grafana.platform.<your-domain>` directly (ALB Ingress via ExternalDNS), or use port-forward if DNS is not yet available:

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open [http://localhost:3000](http://localhost:3000). Username: `admin`. The password is set via the Grafana admin ExternalSecret, which syncs from AWS Secrets Manager (secret name: `grafana-admin`, key: `adminPassword`).

Retrieve it directly from the cluster secret:

```bash
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath="{.data.adminPassword}" | base64 -d; echo
```

Or from AWS Secrets Manager:

```bash
aws secretsmanager get-secret-value --secret-id grafana-admin \
  --query SecretString --output text | jq -r '.adminPassword'
```

## Accessing Prometheus

Prometheus is protected with **basic auth**. The credentials are stored in AWS Secrets Manager (secret name: `prometheus-basic-auth`) and synced via ExternalSecrets.

Open `https://prometheus.platform.<your-domain>` directly, or use port-forward:

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Retrieve the password:

```bash
aws secretsmanager get-secret-value --secret-id prometheus-basic-auth \
  --query SecretString --output text | jq -r '.password'
```

## Accessing Alertmanager

Alertmanager is also protected with **basic auth** (same credentials as Prometheus).

Open `https://alertmanager.platform.<your-domain>` directly, or use port-forward:

```bash
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093
```

---

## Thanos long-term storage

Thanos extends Prometheus with durable, long-term metrics retention backed by the S3 bucket provisioned by `terraform/thanos.tf`.

```
Prometheus ──(sidecar)──▶ S3 bucket (thanos-metrics-<account>-<region>)
                                │
                         StoreGateway (serves historical blocks)
                                │
                          Thanos Query ◀── Grafana
```

The `thanos-objstore-config` Secret is injected at sync-wave 3 (before Thanos at wave 6) with the S3 bucket name and region read directly from the ArgoCD cluster secret annotations set by `bootstrap.sh` / `upgrade.sh`. No manual secret management is required.

**Retention policy (Compactor):**

| Resolution | Retention |
|-----------|-----------|
| Raw (unaggregated) | 30 days |
| 5-minute downsamples | 90 days |
| 1-hour downsamples | 180 days |

To add Thanos as a Grafana datasource pointing at the Query component:

```
URL: http://thanos-query.monitoring.svc.cluster.local:9090
```

Verify Thanos components are running:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos-query
kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos-compactor
kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos-storegateway
```

---

## Prometheus Adapter

The Prometheus Adapter registers itself as a Kubernetes API extension server at `/apis/custom.metrics.k8s.io`. It translates HPA `custom` metric queries into PromQL against the Prometheus server.

Verify the API is registered and serving metrics:

```bash
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1
```

If the API is empty or returns 404, check the adapter logs:

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter
```

---

## SimpleTimeService dashboard

![Grafana Dashboard](../../docs/images/Grafana%20Dashboard.png)

Deployed via `grafana/simple-time-service-dashboard.yaml` - a ConfigMap with label `grafana_dashboard: "1"` in the `monitoring` namespace. Grafana's sidecar detects the label and imports it automatically. No manual steps required.

The dashboard (UID `simple-time-service`, auto-refreshes every 30s) has 12 panels across 5 rows:

| Row | Panels |
|-----|--------|
| Status overview | Scrape status, available replicas, total pods, requests (last 5m) |
| Traffic | Request rate (req/s), latency p50/p95/p99 |
| Request activity | Request activity (1m rate), request count by status code |
| CPU | CPU request vs usage, CPU limit vs usage |
| Memory | Memory request vs usage (MiB), memory limit vs usage (MiB) |

> HTTP traffic panels (rows 2–3) show **No data** until the ServiceMonitor is enabled and the service has received traffic on `/` (not `/health` or `/metrics` - these are filtered out by all traffic queries). Infrastructure panels (rows 1, 4–5) populate from `kube-state-metrics` and cAdvisor regardless.

---

## Verifying the ServiceMonitor

Applies only when the service is deployed with `serviceMonitor.enabled=true` and the `latest` image tag.

```bash
# 1. Confirm the resource exists
kubectl get servicemonitor -n simple-time-service

# 2. Check Prometheus picked it up as a scrape target
# Open https://prometheus.platform.<your-domain>/targets
# or port-forward: kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
# Look for simple-time-service, State: UP

# 3. Confirm metrics are flowing
# In Prometheus UI run: http_requests_total
# Should show time-series with labels handler="/", method="GET"

# 4. Quick end-to-end check
curl https://simple-time-service.platform.<your-domain>/
curl https://simple-time-service.platform.<your-domain>/metrics | grep http_requests_total
```
