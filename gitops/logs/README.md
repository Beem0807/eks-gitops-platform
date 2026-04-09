# Log Aggregation - Loki and Fluent Bit

The `gitops/logs/` directory deploys the full log pipeline via ArgoCD.

| File | What it deploys |
|------|----------------|
| `loki/loki.yaml` | Loki in SingleBinary mode - central log store |
| `loki/grafana-loki-datasource.yaml` | Grafana Loki datasource ConfigMap, auto-provisioned via `charts/raw` |
| `fluent-bit/fluent-bit.yaml` | Fluent Bit DaemonSet - collects and forwards container logs to Loki |

---

## Architecture

```
[Each node] Fluent Bit DaemonSet
    │  tails /var/log/containers/*.log
    │  enriches with Kubernetes metadata
    ▼
loki-gateway.logging.svc.cluster.local
    ▼
Loki (SingleBinary, logging namespace)
    ▼
Grafana datasource ConfigMap (monitoring namespace)
    │  auto-provisioned by grafana-sidecar
    ▼
Grafana → Explore → LogQL
```

Sync-wave ordering ensures Loki is running before Fluent Bit and the datasource are applied:

| Component | Sync wave |
|-----------|-----------|
| Loki | 3 |
| Fluent Bit | 4 |
| Grafana Loki datasource | 4 |

---

## Loki

Runs in `SingleBinary` mode - all components in one pod. Suitable for demos and development.

| Setting | Value | Notes |
|---------|-------|-------|
| Mode | `SingleBinary` | One pod, all components |
| Storage | `filesystem` on `emptyDir` | **Logs are lost on pod restart** - use S3/GCS in production |
| Replication | `1` | No redundancy |
| Schema | `v13` (TSDB, from `2024-01-01`) | Current recommended schema |
| Auth | disabled (`auth_enabled: false`) | Single-tenant mode |
| Gateway | enabled | Exposes `loki-gateway` ClusterIP used by Fluent Bit and Grafana |

---

## Fluent Bit

Runs as a DaemonSet in the `logging` namespace - one pod per node.

**Input:** `tail` plugin reads all container logs from `/var/log/containers/*.log` using the `docker` and `cri` multiline parsers.

**Filter:** `kubernetes` plugin enriches each log record with namespace, pod name, container name, and other Kubernetes labels.

**Output:** `loki` plugin forwards enriched logs to the Loki gateway with these labels:

| Label | Value |
|-------|-------|
| `job` | `fluent-bit` |
| `namespace` | `$kubernetes['namespace_name']` |
| `pod` | `$kubernetes['pod_name']` |
| `container` | `$kubernetes['container_name']` |

---

## Grafana Loki datasource

A ConfigMap with label `grafana_datasource: "1"` deployed into the `monitoring` namespace. Grafana's sidecar detects it and provisions the datasource automatically - no manual configuration needed.

| Setting | Value |
|---------|-------|
| Name | `Loki` |
| Type | `loki` |
| URL | `http://loki-gateway.logging.svc.cluster.local` |
| Default | No (Prometheus remains the default) |

---

## Querying logs in Grafana

![Loki Logs](../../docs/images/logs.png)

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open [http://localhost:3000](http://localhost:3000) → **Explore** → select **Loki** datasource.

```logql
# All logs from the service namespace
{namespace="simple-time-service"}

# Logs from a specific container
{namespace="simple-time-service", container="simple-time-service"}

# Filter for error lines
{namespace="simple-time-service"} |= "ERROR"
```

---

## Verifying Loki is receiving logs

```bash
# Check pods are running
kubectl get pods -n logging

# Port-forward the Loki gateway
kubectl port-forward svc/loki-gateway -n logging 3100:80

# Query available labels (non-empty response = logs are flowing)
curl 'http://localhost:3100/loki/api/v1/labels'
```
