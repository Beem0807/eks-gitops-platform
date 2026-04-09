# Helm Chart - simple-time-service

The chart at `charts/simple-time-service/` is the recommended way to deploy the service to Kubernetes. It provides configurable replicas, resource limits, health probes, a PodDisruptionBudget, HPA-based autoscaling, and a full set of security-context defaults - all tuneable through `values.yaml`.

> The raw manifest at `k8s/microservice.yaml` is a minimal alternative for quickly testing the service. The Helm chart is the configurable deployment used by ArgoCD in this platform.

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

## Chart values

All values can be overridden with `--set key=value` or a custom values file (`-f my-values.yaml`).

| Key | Default | Description |
|-----|---------|-------------|
| `fullnameOverride` | `simple-time-service` | Override the full resource name |
| `replicaCount` | `2` | Number of pod replicas |
| `image.repository` | `docker.io/nabeemdev/simple-time-service` | Container image repository |
| `image.tag` | `v1` | Image tag (`v1` = baseline, `latest` = metrics-enabled build) |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `service.type` | `ClusterIP` | Kubernetes Service type |
| `service.port` | `80` | Service port |
| `service.targetPort` | `8080` | Container port |
| `resources.requests.cpu` | `100m` | CPU request |
| `resources.requests.memory` | `128Mi` | Memory request |
| `resources.limits.cpu` | `250m` | CPU limit |
| `resources.limits.memory` | `256Mi` | Memory limit |
| `livenessProbe.path` | `/health` | Liveness probe HTTP path |
| `livenessProbe.initialDelaySeconds` | `5` | Liveness probe initial delay |
| `livenessProbe.periodSeconds` | `10` | Liveness probe interval |
| `readinessProbe.path` | `/health` | Readiness probe HTTP path |
| `readinessProbe.initialDelaySeconds` | `3` | Readiness probe initial delay |
| `readinessProbe.periodSeconds` | `5` | Readiness probe interval |
| `podSecurityContext.runAsNonRoot` | `true` | Enforce non-root at pod level |
| `podSecurityContext.runAsUser` | `10001` | UID for the container process |
| `podSecurityContext.runAsGroup` | `10001` | GID for the container process |
| `podSecurityContext.fsGroup` | `10001` | GID for volume mounts |
| `securityContext.allowPrivilegeEscalation` | `false` | Prevent privilege escalation |
| `securityContext.readOnlyRootFilesystem` | `true` | Read-only root filesystem |
| `securityContext.capabilities.drop` | `["ALL"]` | Drop all Linux capabilities |
| `serviceAccount.create` | `false` | Create a dedicated ServiceAccount |
| `serviceAccount.name` | `""` | ServiceAccount name (if not auto-generated) |
| `serviceAccount.annotations` | `{}` | Annotations for the ServiceAccount |
| `networkPolicy.enabled` | `false` | Create a NetworkPolicy restricting ingress and egress |
| `hpa.enabled` | `false` | Create a HorizontalPodAutoscaler (requires `metrics-server`) |
| `hpa.minReplicas` | `2` | Minimum number of replicas |
| `hpa.maxReplicas` | `10` | Maximum number of replicas |
| `hpa.targetCPUAverageUtilization` | `70` | Target average CPU utilization across pods |
| `hpa.scaleDown.stabilizationWindowSeconds` | `300` | Seconds to wait after load drops before scaling down |
| `hpa.scaleDown.pods` | `1` | Max pods to remove per scale-down period |
| `hpa.scaleDown.periodSeconds` | `60` | Scale-down policy period length in seconds |
| `hpa.scaleUp.stabilizationWindowSeconds` | `0` | Seconds to wait before scaling up (0 = immediate) |
| `hpa.scaleUp.pods` | `2` | Max pods to add per scale-up period |
| `hpa.scaleUp.periodSeconds` | `30` | Scale-up policy period length in seconds |
| `pdb.enabled` | `true` | Create a PodDisruptionBudget |
| `pdb.minAvailable` | `1` | Minimum pods available during disruptions |
| `serviceMonitor.enabled` | `false` | Create a Prometheus `ServiceMonitor` (requires Prometheus Operator) |
| `serviceMonitor.interval` | `30s` | Scrape interval |
| `serviceMonitor.path` | `/metrics` | Metrics endpoint path |
| `serviceMonitor.labels` | `{}` | Extra labels added to the `ServiceMonitor` |
| `podAnnotations` | `{}` | Extra pod annotations |
| `nodeSelector` | `{}` | Node selector constraints |
| `tolerations` | `[]` | Pod tolerations |
| `affinity` | `{}` | Pod affinity/anti-affinity rules |

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
