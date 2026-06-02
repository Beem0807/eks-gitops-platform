# Loki No Logs / Logs Not Appearing

## Symptoms

- Grafana Explore → Loki datasource returns "No data" for a namespace or label selector
- `{namespace="<ns>", app="<app>"}` query returns empty
- New pods have been running for > 5 minutes but logs are absent
- `kubectl logs <pod>` shows output, but Grafana/Loki does not
- Fluent Bit pod is crash-looping or shows errors in logs

## Impact

- **High**: Operational blindness - incidents cannot be investigated in real time
- **Medium**: Historical logs missing but `kubectl logs` still works for live debugging

## Quick Checks

```bash
# Fluent Bit DaemonSet - one pod per node expected
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit -o wide

# Fluent Bit logs - look for OUTPUT errors or backpressure
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=100

# Loki pod (runs as SingleBinary)
kubectl get pods -n logging -l app.kubernetes.io/name=loki

# Loki logs
kubectl logs -n logging -l app.kubernetes.io/name=loki --tail=100

# Test Loki is reachable and accepting queries via the gateway
kubectl port-forward -n logging svc/loki-gateway 3100:80
curl -s http://localhost:3100/loki/api/v1/labels

# Check S3 bucket access
aws s3 ls s3://<loki-bucket-name>/ --region <region>
```

> **This platform**: Fluent Bit sends logs to `loki-gateway.logging.svc.cluster.local:80` (the Loki gateway Service), not directly to `loki`. The Grafana datasource URL is `http://loki-gateway.logging.svc.cluster.local` (no explicit port - defaults to 80).

## Root Causes

| Cause | How to Identify |
|---|---|
| Fluent Bit not running on a node | `kubectl get pods -n logging -o wide` - node has no Fluent Bit pod |
| Fluent Bit can't reach Loki gateway | Fluent Bit logs show `connection refused` or `timeout` to loki-gateway |
| Loki pod OOMKilled | `kubectl describe pod -n logging loki-*` shows OOMKilled |
| S3 backend permissions broken | Loki logs: `AccessDenied` writing to S3 |
| Grafana datasource URL wrong | Datasource test in Grafana shows `Bad Gateway` |
| Ingestion rate limit hit | Loki logs: `429 Too Many Requests`; Fluent Bit shows backpressure |
| Loki retention purged the data | Query is for a time range older than configured retention |

## Fix

### Fluent Bit crash-looping
```bash
kubectl describe pod -n logging <fluent-bit-pod>
kubectl logs -n logging <fluent-bit-pod> --previous

# Most common cause: Loki gateway URL misconfigured in Fluent Bit OUTPUT
# Check gitops/logs/fluent-bit/fluent-bit.yaml - OUTPUT section should have:
#   Host loki-gateway.logging.svc.cluster.local
#   Port 80
#   Uri /loki/api/v1/push

kubectl rollout restart daemonset fluent-bit -n logging
```

### Fluent Bit can't reach Loki gateway
```bash
# Test from a Fluent Bit pod
kubectl exec -n logging <fluent-bit-pod> -- \
  wget -qO- http://loki-gateway.logging.svc.cluster.local/loki/api/v1/labels

# Check if a NetworkPolicy in the logging namespace blocks the traffic
kubectl get networkpolicy -n logging
```

### Loki OOMKilled
```bash
kubectl describe pod -n logging loki-0 | grep -A 5 "OOMKilled\|Limits"
```

> **This platform**: Loki runs in **SingleBinary** mode (`deploymentMode: SingleBinary`). Memory limits are under `singleBinary.resources` in `gitops/logs/loki/loki.yaml` - not `loki.resources`.

```yaml
# gitops/logs/loki/loki.yaml - increase under singleBinary
singleBinary:
  resources:
    limits:
      memory: 2Gi   # raise this
```

### Loki S3 backend access denied
```bash
# Check IRSA annotation on the Loki service account
kubectl get sa loki -n logging -o jsonpath='{.metadata.annotations}'

# Verify S3 bucket exists and the role has access
aws s3 ls s3://<loki-bucket-name>/ --region <region>
```

> **This platform**: IRSA role follows pattern `<cluster-name>-loki-irsa`. S3 bucket name follows `<cluster-name>-loki-logs-<account-id>-<region>`. Both are created in `terraform/loki.tf`. If access is denied, re-apply:
```bash
cd terraform && terraform apply -target=module.loki_irsa
```

### Ingestion rate limit hit
```bash
kubectl logs -n logging -l app.kubernetes.io/name=loki | grep "429\|rate_limit"

# Temporarily raise limits in gitops/logs/loki/loki.yaml:
# loki.limits_config.ingestion_rate_mb: 16
# loki.limits_config.ingestion_burst_size_mb: 32
```

### Grafana datasource URL wrong
```bash
# Verify the ConfigMap Grafana loads as a datasource
kubectl get configmap grafana-loki-datasource -n monitoring -o yaml | grep url
```

Expected value: `http://loki-gateway.logging.svc.cluster.local`

Defined in `gitops/logs/loki/grafana-loki-datasource.yaml`.

## Prevention

- Monitor Fluent Bit with a `fluentbit_output_errors_total > 0` alert
- Alert on `loki_ingester_streams_created_total` dropping to zero - indicates no new logs are being ingested
- Run `kubectl logs <pod> | head -5` as a smoke test in CI when adding new node types to confirm the logging driver works
- Document Loki retention period when set - queries beyond that window will silently return empty
