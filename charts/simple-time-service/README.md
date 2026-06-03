# simple-time-service

Helm chart for the simple-time-service app

> The raw manifest at `k8s/microservice.yaml` is a minimal alternative for quickly testing the service. The Helm chart is the configurable deployment used by ArgoCD in this platform.

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1](https://img.shields.io/badge/AppVersion-v1-informational?style=flat-square)

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Helm](https://helm.sh/docs/intro/install/) `>= 3` | Package manager for Kubernetes |
| A running Kubernetes cluster | Deployment target |

---

## Install

```bash
# Into the default namespace
helm install simple-time-service charts/simple-time-service

# Into a custom namespace
kubectl create namespace simple-time-service
helm install simple-time-service charts/simple-time-service --namespace simple-time-service
```

## Upgrade

```bash
helm upgrade simple-time-service charts/simple-time-service
helm upgrade simple-time-service charts/simple-time-service --namespace simple-time-service
```

## Verify the deployment

```bash
kubectl rollout status deployment/simple-time-service -n simple-time-service
kubectl get pods -n simple-time-service -l app.kubernetes.io/name=simple-time-service
```

## Access the service

```bash
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
curl http://127.0.0.1:8080/
```

## Uninstall

```bash
helm uninstall simple-time-service --namespace simple-time-service
kubectl delete namespace simple-time-service
```

---

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Pod affinity/anti-affinity rules |
| fullnameOverride | string | `"simple-time-service"` | Override the full resource name used by all chart objects |
| hpa.enabled | bool | `false` | Create a HorizontalPodAutoscaler (requires `metrics-server`) |
| hpa.maxReplicas | int | `10` | Maximum number of replicas the HPA may scale to |
| hpa.minReplicas | int | `2` | Minimum number of replicas the HPA will maintain |
| hpa.scaleDown.periodSeconds | int | `60` | Scale-down policy period length in seconds |
| hpa.scaleDown.pods | int | `1` | Maximum pods to remove per scale-down period |
| hpa.scaleDown.stabilizationWindowSeconds | int | `300` | Seconds to wait after load drops before scaling down |
| hpa.scaleUp.periodSeconds | int | `30` | Scale-up policy period length in seconds |
| hpa.scaleUp.pods | int | `2` | Maximum pods to add per scale-up period |
| hpa.scaleUp.stabilizationWindowSeconds | int | `0` | Seconds to wait before scaling up (0 = immediate) |
| hpa.targetCPUAverageUtilization | int | `70` | Target average CPU utilization across all pods (percent) |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| image.repository | string | `"docker.io/nabeemdev/simple-time-service"` | Container image repository |
| image.tag | string | `"v1"` | Image tag (`v1` = baseline, `latest` = metrics-enabled build) |
| ingress.annotations | object | `{}` | Ingress annotations (e.g. ALB scheme, target type) |
| ingress.className | string | `""` | Ingress class name (e.g. `alb`) |
| ingress.enabled | bool | `false` | Create an Ingress resource |
| ingress.hosts | list | `[]` | List of `{host, paths[]}` entries |
| ingress.tls | list | `[]` | TLS configuration for the Ingress |
| livenessProbe.initialDelaySeconds | int | `5` | Seconds before the first liveness probe fires |
| livenessProbe.path | string | `"/health"` | Liveness probe HTTP path |
| livenessProbe.periodSeconds | int | `10` | Liveness probe polling interval in seconds |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy that restricts ingress and egress to labelled pods |
| nodeSelector | object | `{}` | Node selector constraints for pod scheduling |
| pdb.enabled | bool | `true` | Create a PodDisruptionBudget |
| pdb.minAvailable | int | `1` | Minimum pods that must remain available during voluntary disruptions |
| podAnnotations | object | `{}` | Extra annotations added to every pod |
| podSecurityContext.fsGroup | int | `10001` | GID applied to volume mounts |
| podSecurityContext.runAsGroup | int | `10001` | GID for the container process |
| podSecurityContext.runAsNonRoot | bool | `true` | Enforce that the container runs as a non-root user |
| podSecurityContext.runAsUser | int | `10001` | UID for the container process |
| readinessProbe.initialDelaySeconds | int | `3` | Seconds before the first readiness probe fires |
| readinessProbe.path | string | `"/health"` | Readiness probe HTTP path |
| readinessProbe.periodSeconds | int | `5` | Readiness probe polling interval in seconds |
| replicaCount | int | `2` | Number of pod replicas |
| resources.limits.cpu | string | `"250m"` | CPU limit |
| resources.limits.memory | string | `"256Mi"` | Memory limit |
| resources.requests.cpu | string | `"100m"` | CPU request |
| resources.requests.memory | string | `"128Mi"` | Memory request |
| securityContext.allowPrivilegeEscalation | bool | `false` | Prevent the container from gaining new privileges |
| securityContext.capabilities.drop | list | `["ALL"]` | Linux capabilities to drop from the container |
| securityContext.readOnlyRootFilesystem | bool | `true` | Mount the root filesystem read-only |
| service.annotations | object | `{}` | Extra annotations to add to the Service |
| service.port | int | `80` | Service port exposed to the cluster |
| service.targetPort | int | `8080` | Container port the service forwards traffic to |
| service.type | string | `"ClusterIP"` | Kubernetes Service type |
| serviceAccount.annotations | object | `{}` | Annotations added to the ServiceAccount |
| serviceAccount.create | bool | `false` | Create a dedicated ServiceAccount for the deployment |
| serviceAccount.name | string | `""` | ServiceAccount name; auto-generated if empty and `create` is true |
| serviceMonitor.enabled | bool | `false` | Create a Prometheus ServiceMonitor (requires Prometheus Operator) |
| serviceMonitor.interval | string | `"30s"` | Prometheus scrape interval |
| serviceMonitor.labels | object | `{}` | Extra labels added to the ServiceMonitor (used to target a specific Prometheus instance) |
| serviceMonitor.path | string | `"/metrics"` | Metrics endpoint path |
| tolerations | list | `[]` | Pod tolerations |
| tracing.agentPort | int | `4318` | OTLP HTTP port on the node-local OTel Collector agent; used only when `endpoint` is empty |
| tracing.enabled | bool | `false` | Enable OpenTelemetry tracing |
| tracing.endpoint | string | `""` | Direct OTLP HTTP endpoint (e.g. `http://otel-collector.tracing.svc.cluster.local:4318`). When empty, uses the node-local DaemonSet agent via `status.hostIP:agentPort` |
| tracing.serviceName | string | `"simple-time-service"` | Service name reported in traces and correlated in Grafana Tempo |

---

## Examples

### Deploy without metrics (v1)

```bash
helm install simple-time-service charts/simple-time-service \
  --set image.tag=v1
```

### Deploy with Prometheus metrics (latest)

Requires Prometheus Operator to be installed on the cluster.

```bash
helm install simple-time-service charts/simple-time-service \
  --set image.tag=latest \
  --set serviceMonitor.enabled=true
```

### Deploy with tracing enabled

Requires the OTel Collector DaemonSet to be running on each node (deployed via `gitops/tracing/`).

```bash
helm install simple-time-service charts/simple-time-service \
  --set image.tag=latest \
  --set serviceMonitor.enabled=true \
  --set tracing.enabled=true
```

The chart injects `NODE_IP` (via the downward API) and constructs `OTEL_EXPORTER_OTLP_ENDPOINT=http://$(NODE_IP):4318` automatically so pods always reach the node-local agent without any manual endpoint configuration.

---

## Updating this README

This file is auto-generated by [helm-docs](https://github.com/norwoodj/helm-docs). Do **not** edit `README.md` directly - edit `README.md.gotmpl` for structural changes or annotate `values.yaml` keys with `# --` comments to update the values table.

**Requires:** `helm-docs >= 1.11` - install from the [official guide](https://github.com/norwoodj/helm-docs#installation).

Regenerate after any change:

```bash
helm-docs --chart-search-root charts/
```
