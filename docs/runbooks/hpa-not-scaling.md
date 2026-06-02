# HPA Not Scaling

## Symptoms

- Pod count stays at minimum replicas despite high CPU/memory or custom metrics
- `kubectl get hpa -n <ns>` shows `<unknown>` in TARGETS column
- `kubectl describe hpa <name>` shows `FailedGetScale` or `FailedComputeMetricsReplicas` events
- Latency/error-rate alerts fire while replica count does not increase
- `kubectl top pods` shows pods at or near resource limits

## Impact

- **High**: Service is under load; existing pods are saturated; users see elevated latency or errors
- Application SLO at risk until scaling resumes

## Quick Checks

```bash
# Overview - check TARGETS and REPLICAS
kubectl get hpa -n <namespace> -o wide

# Detailed events and conditions
kubectl describe hpa <hpa-name> -n <namespace>

# Verify metrics-server is running and healthy
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server
kubectl top nodes
kubectl top pods -n <namespace>

# Check if custom metrics (prometheus-adapter) are available
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq .

# For external metrics (e.g. SQS queue depth)
kubectl get --raw /apis/external.metrics.k8s.io/v1beta1 | jq .

# Confirm resource requests are set on the target deployment
kubectl get deployment <name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[*].resources}'
```

## Root Causes

| Cause | How to Identify |
|---|---|
| metrics-server not running or crashing | `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server` shows 0/1 |
| No `resources.requests` on container | HPA targets show `<unknown>`; `describe hpa` shows `missing request for cpu` |
| prometheus-adapter misconfigured | Custom metric missing from `/apis/custom.metrics.k8s.io/v1beta1` |
| HPA at `maxReplicas` already | `kubectl get hpa` shows REPLICAS == MAX |
| PodDisruptionBudget blocking scale-down but not scale-up | Confirm scale-*up* is the actual issue |
| Karpenter/CA can't provision nodes | New pods stuck in `Pending`; node provisioning runbook applies |
| RBAC: metrics API forbidden | `describe hpa` shows `403` or `Forbidden` events |
| Cluster-level resource quota exhausted | `kubectl describe resourcequota -n <namespace>` |

## Fix

### metrics-server not working
```bash
# Restart metrics-server
kubectl rollout restart deployment metrics-server -n kube-system

# Verify it recovers
kubectl rollout status deployment metrics-server -n kube-system
kubectl top nodes   # should return data within ~60s
```

### Missing resource requests
```yaml
# In the chart values (charts/simple-time-service/values.yaml) or HelmRelease
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```
Commit → ArgoCD syncs → HPA targets become numeric.

### prometheus-adapter custom metric missing
```bash
# Check adapter config
kubectl get configmap -n monitoring adapter-config -o yaml

# Check adapter logs for scrape/parse errors
kubectl logs -n monitoring -l app=prometheus-adapter --tail=100

# Verify the backing PromQL query returns data
# Port-forward Prometheus and run the query manually
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Then in browser: http://localhost:9090
```

Update `gitops/monitoring/prometheus/prometheus-adapter.yaml` with correct series name / label matchers, commit, and re-sync.

### HPA already at maxReplicas
```bash
# Temporary: raise maxReplicas in the HelmRelease / values
kubectl patch hpa <name> -n <namespace> --type='json' \
  -p='[{"op":"replace","path":"/spec/maxReplicas","value":20}]'
# Follow up: commit the new value to the chart
```

### RBAC for metrics API
```bash
# Confirm HPA controller can read the metrics API
kubectl auth can-i get pods.metrics.k8s.io --as=system:serviceaccount:kube-system:horizontal-pod-autoscaler
```
Fix by ensuring the `metrics-server` APIService is registered and healthy:
```bash
kubectl get apiservice v1beta1.metrics.k8s.io
```

## Prevention

- Always set `resources.requests` in Helm chart defaults - add a Kyverno policy to deny pods without requests
- Run load tests (`scripts/k6-staged.js`) and confirm HPA fires before promoting to production
- Alert on `hpa_current_replicas == hpa_max_replicas` for sustained periods to catch ceiling-hits early
- Include `minReplicas ≥ 2` in chart defaults to maintain availability during scale events
- Validate prometheus-adapter custom metric rules in CI with `kubectl get --raw` after every adapter config change
