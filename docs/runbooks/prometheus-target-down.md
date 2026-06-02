# Prometheus Target Down

## Symptoms

- Alertmanager fires `PrometheusTargetMissing` or `TargetDown` alert
- Grafana dashboard shows gaps or "No data" for a service
- Prometheus UI (Status → Targets) shows a target in `DOWN` state
- `up{job="<job>"}` returns `0` in PromQL

## Impact

- **Medium**: Metrics collection stopped - no immediate user impact, but SLO tracking and alerting for that component are blind
- **High**: If Prometheus or kube-state-metrics / node-exporter targets are down, cluster-wide visibility is lost

## Quick Checks

```bash
# Port-forward to Prometheus and check Status → Targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/targets

# Prometheus operator logs
kubectl logs -n monitoring \
  -l app.kubernetes.io/name=prometheus-operator --tail=100

# Prometheus pod logs
kubectl logs -n monitoring \
  prometheus-kube-prometheus-prometheus-0 --tail=100

# List all ServiceMonitors across all namespaces
kubectl get servicemonitor -A

# Describe the ServiceMonitor for the failing job
kubectl describe servicemonitor <name> -n <namespace>

# Is the backing Service present and has endpoints?
kubectl get svc -n <namespace> <service-name>
kubectl get endpoints -n <namespace> <service-name>

# Does the pod actually expose /metrics?
kubectl exec -n <namespace> <pod-name> -- \
  wget -qO- http://localhost:<metrics-port>/metrics | head -5
```

## Root Causes

| Cause | How to Identify |
|---|---|
| App pod not running / not ready | No endpoints on the backing Service |
| ServiceMonitor `selector.matchLabels` doesn't match Service labels | `describe servicemonitor` selector ≠ `kubectl get svc --show-labels` |
| ServiceMonitor port name doesn't match Service port name | Port named `http` in ServiceMonitor but Service uses a different name |
| NetworkPolicy blocking Prometheus scrape | Prometheus pods can't reach app pods on metrics port |
| Prometheus OOMKilled | `kubectl describe pod prometheus-kube-prometheus-prometheus-0` shows OOMKilled |
| kube-state-metrics crash-looping | `kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics` |
| node-exporter pod absent on a new node | New Karpenter node not yet running node-exporter |

> **This platform**: `serviceMonitorSelectorNilUsesHelmValues: false` is set on the Prometheus spec. This means Prometheus watches **all ServiceMonitors across all namespaces** - there is no namespace label requirement. Do not waste time adding labels to namespaces.

## Fix

### ServiceMonitor selector mismatch
```bash
# Get the actual labels on the Service
kubectl get svc <service-name> -n <namespace> --show-labels

# Compare with what the ServiceMonitor selects
kubectl get servicemonitor <name> -n <namespace> \
  -o jsonpath='{.spec.selector.matchLabels}'
```

Update the ServiceMonitor's `selector.matchLabels` to match and commit via GitOps.

> **This platform**: The simple-time-service ServiceMonitor is in `charts/simple-time-service/templates/servicemonitor.yaml`. It selects using the chart's `selectorLabels` (i.e., `app.kubernetes.io/name: simple-time-service`). The Service port is named `http`.

### NetworkPolicy blocking scrape
```bash
# Test connectivity from a Prometheus pod
kubectl exec -n monitoring prometheus-kube-prometheus-prometheus-0 -- \
  wget -qO- http://<pod-ip>:<metrics-port>/metrics | head -3
```

If blocked, add an ingress rule to the app's NetworkPolicy:
```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: monitoring
    ports:
      - port: <metrics-port>
```

> **This platform**: NetworkPolicy is disabled by default (`networkPolicy.enabled: false` in `charts/simple-time-service/values.yaml`). If it gets enabled, the template already includes the `monitoring` namespace ingress rule - verify it's present.

### Prometheus OOMKilled
```bash
kubectl describe pod -n monitoring prometheus-kube-prometheus-prometheus-0 \
  | grep -A 5 "OOMKilled\|Limits"

# Increase memory in gitops/monitoring/prometheus/prometheus.yaml
# Under: prometheusSpec.resources.limits.memory
```

Prometheus local retention is `7d` - increasing retention without increasing memory will also cause OOM.

### prometheus-adapter custom metric missing
The adapter config lives inside the ArgoCD HelmRelease values in `gitops/monitoring/prometheus/prometheus-adapter.yaml` - there is no standalone ConfigMap to inspect directly.

```bash
# Verify the adapter is running (2 replicas)
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-adapter

# Check adapter logs for scrape/parse errors
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter --tail=100

# Verify the custom metrics API is reachable
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq .
```

> **This platform**: The adapter points at `http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090`. If that Service name changes (e.g., Helm release rename), the adapter URL in `gitops/monitoring/prometheus/prometheus-adapter.yaml` must be updated.

### kube-state-metrics or node-exporter down
```bash
kubectl rollout restart deployment kube-state-metrics -n monitoring
kubectl rollout restart daemonset prometheus-node-exporter -n monitoring
```

## Prevention

> **This platform**: Grafana is configured with **Thanos** as the default datasource (`http://thanos-query.monitoring.svc.cluster.local:9090`), not Prometheus directly. Gaps in Grafana can mean either Prometheus collection is broken *or* Thanos Query/Store is unhealthy - check both.

- Validate `up{job="<job>"}` returns `1` in Prometheus UI as a post-deploy smoke test
- Alert on `prometheus_tsdb_head_series > 5_000_000` to catch memory pressure before OOM
- Confirm ServiceMonitor port names match Service port names in Helm chart lint CI
