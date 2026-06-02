# Thanos No Metrics / Grafana Shows No Data

## Symptoms

- Grafana dashboards show "No data" across all panels
- Queries return empty in Grafana Explore
- `kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus` shows Prometheus healthy
- PromQL works fine when port-forwarding directly to Prometheus but not in Grafana
- Thanos Query or StoreGateway pod is crash-looping or not ready

## Impact

- **High**: All Grafana dashboards are blind even though Prometheus is collecting metrics normally
- Alerting via Prometheus rules is unaffected - only the Grafana query path is broken
- Long-term metrics (older than Prometheus `7d` local retention) are inaccessible even if Thanos recovers

## Quick Checks

```bash
# Thanos component pod status
kubectl get pods -n monitoring -l app.kubernetes.io/name=thanos

# Query pod logs
kubectl logs -n monitoring -l app.kubernetes.io/component=query --tail=100

# StoreGateway pod logs
kubectl logs -n monitoring \
  -l app.kubernetes.io/component=storegateway --tail=100

# Compactor pod logs
kubectl logs -n monitoring \
  -l app.kubernetes.io/component=compactor --tail=100

# Is Thanos Query reachable?
kubectl port-forward -n monitoring svc/thanos-query 9090:9090
# Open http://localhost:9090 - run a simple query like "up"

# Is the Prometheus sidecar (Thanos sidecar) healthy?
kubectl get pod -n monitoring prometheus-kube-prometheus-prometheus-0 \
  -o jsonpath='{.status.containerStatuses[*].name}'
# Should include "thanos-sidecar"

# Check the sidecar discovery service
kubectl get endpoints -n monitoring \
  prometheus-kube-prometheus-thanos-discovery
```

> **This platform**: Grafana is configured with **Thanos Query** as the default datasource (`http://thanos-query.monitoring.svc.cluster.local:9090`). Prometheus is not a Grafana datasource. "No data" in Grafana means Thanos is unhealthy, not Prometheus.

## Root Causes

| Cause | How to Identify |
|---|---|
| Thanos Query pod down | `kubectl get pods -n monitoring` shows query not ready |
| StoreGateway down - historical data inaccessible | Query logs: `no store found`; only recent data works |
| Prometheus sidecar unhealthy | Sidecar container in the Prometheus pod is `Error` or not present |
| S3 bucket access denied (sidecar or storegateway) | Logs show `AccessDenied` writing/reading from S3 |
| Sidecar discovery service has no endpoints | `kubectl get endpoints prometheus-kube-prometheus-thanos-discovery` is empty |
| Thanos StoreGateway PVC stuck (AZ mismatch) | StoreGateway pod in `Pending` or `ContainerCreating` - follow ebs-pvc-not-mounting runbook |
| Compactor crash-looping | Compactor logs show S3 errors; does not affect reads but causes S3 bloat |

## Fix

### Thanos Query pod not running
```bash
kubectl rollout restart deployment thanos-query -n monitoring
kubectl rollout status deployment thanos-query -n monitoring
```

### Sidecar discovery has no endpoints
Thanos Query discovers the Prometheus sidecar via the `prometheus-kube-prometheus-thanos-discovery` service.
```bash
# Check endpoints
kubectl describe endpoints prometheus-kube-prometheus-thanos-discovery -n monitoring

# If empty, the sidecar is not running - check the Prometheus pod
kubectl describe pod prometheus-kube-prometheus-prometheus-0 -n monitoring \
  | grep -A 5 "thanos-sidecar"

# Restart Prometheus StatefulSet to recover the sidecar
kubectl rollout restart statefulset \
  prometheus-kube-prometheus-prometheus -n monitoring
```

### S3 access denied
> **This platform**: Two IRSA roles handle S3 access:
> - **Prometheus sidecar** (writing blocks): `<cluster-name>-thanos-prometheus-irsa` - annotated on the `prometheus-kube-prometheus-prometheus` service account
> - **Compactor + StoreGateway** (reading/compacting): `<cluster-name>-thanos-components-irsa` - annotated on `thanos-compactor` and `thanos-storegateway` service accounts
>
> The object store config (bucket name, region) is in the `thanos-objstore-config` secret in the `monitoring` namespace.

```bash
# Check sidecar IRSA
kubectl get sa prometheus-kube-prometheus-prometheus -n monitoring \
  -o jsonpath='{.metadata.annotations}'

# Check storegateway IRSA
kubectl get sa thanos-storegateway -n monitoring \
  -o jsonpath='{.metadata.annotations}'

# Verify bucket is accessible
aws s3 ls s3://<thanos-bucket>/ --region <region>

# If role is wrong, re-apply
cd terraform && terraform apply -target=module.thanos_irsa
```

### StoreGateway PVC stuck
```bash
kubectl describe pod -n monitoring -l app.kubernetes.io/component=storegateway \
  | grep -A 5 "Events\|ContainerCreating"
# If EBS AZ mismatch - follow ebs-pvc-not-mounting.md runbook
```

### Compactor crash-looping
The compactor does not affect read availability. It can be left degraded temporarily while investigating S3 issues.
```bash
kubectl logs -n monitoring -l app.kubernetes.io/component=compactor --tail=100
# Most common cause: S3 access denied or bucket policy changed
```

## Prevention

- Alert on `thanos_query_store_apis_up < 1` - fires when Query has no reachable stores
- Alert on Thanos Query pod restarts
- After any IAM/IRSA change, verify Thanos sidecar can still write to S3 within one Prometheus block interval (2h)
- Include a Thanos Query health check in post-deploy smoke tests: `curl http://thanos-query:9090/-/healthy`
