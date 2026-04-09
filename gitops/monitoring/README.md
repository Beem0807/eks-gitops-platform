# Monitoring - Prometheus and Grafana

The `gitops/monitoring/` directory deploys the full observability stack via ArgoCD.

| File | What it deploys |
|------|----------------|
| `prometheus/prometheus.yaml` | `kube-prometheus-stack` - Prometheus, Grafana, Alertmanager, Prometheus Operator |
| `grafana/simple-time-service-dashboard.yaml` | Pre-built Grafana dashboard for SimpleTimeService via `charts/raw` |

---

## What gets deployed

| Component | Details |
|-----------|---------|
| Prometheus | Metrics collection, 7-day retention |
| Grafana | Dashboards UI, auto-provisioned with Prometheus and Loki datasources |
| Alertmanager | Alert routing and grouping |
| Prometheus Operator | Manages `PrometheusRule` and `ServiceMonitor` CRDs |
| kube-state-metrics | Kubernetes object/state metrics (Deployments, Pods, resource requests) |

All components land in the `monitoring` namespace, created automatically by ArgoCD via `CreateNamespace=true`.

---

## Key configuration

`serviceMonitorSelectorNilUsesHelmValues: false` - tells Prometheus to discover `ServiceMonitor` resources across **all namespaces**. Without this, the `ServiceMonitor` in the `simple-time-service` namespace is silently ignored.

Prometheus Operator TLS and admission webhooks are disabled to simplify bootstrap. Enable them in production.

`KubeSchedulerDown` and `KubeControllerManagerDown` alerts are suppressed - on EKS the control plane is managed by AWS and never exposed for scraping, so these would fire permanently.

---

## Accessing Grafana

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open [http://localhost:3000](http://localhost:3000). Default username: `admin`. If the password is unknown:

```bash
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

## Accessing Prometheus

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Open [http://localhost:9090](http://localhost:9090).

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
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
# Open http://localhost:9090/targets - look for simple-time-service, State: UP

# 3. Confirm metrics are flowing
# In Prometheus UI run: http_requests_total
# Should show time-series with labels handler="/", method="GET"

# 4. Quick end-to-end check
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
curl http://localhost:8080/
curl http://localhost:8080/metrics | grep http_requests_total
```
