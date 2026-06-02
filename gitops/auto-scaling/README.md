# Autoscaling

The `gitops/auto-scaling/` directory deploys four ArgoCD apps that together handle node and pod scaling.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `cluster-autoscaler/cluster-autoscaler.yaml` | Cluster Autoscaler v1.33.0 - scales the core managed node group | 1 | `kube-system` |
| `karpenter/karpenter.yaml` | Karpenter v1.0.8 controller - provisions workload nodes on demand | 3 | `karpenter` |
| `karpenter/karpenter-nodepools.yaml` | `EC2NodeClass` + `NodePool` for workload nodes | 4 | `karpenter` |
| `metrics-server/metrics-server.yaml` | metrics-server v3.12.2 - CPU/memory metrics API required by HPA | — | `kube-system` |

Wave ordering ensures the Karpenter controller is running and its admission webhook cert is propagated before the `EC2NodeClass` and `NodePool` CRDs are applied.

---

## Node architecture: core vs workload

The cluster uses two distinct node pools with separate taints to isolate system workloads from application workloads.

```
┌─────────────────────────────────────────────┐
│  Managed Node Group (core)                  │
│  label: app=core  taint: app=core:NoSchedule│
│                                             │
│  ArgoCD, Prometheus, Karpenter, LBC,        │
│  ExternalDNS, ExternalSecrets, Loki, etc.   │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  Karpenter NodePool (workload)              │
│  label: app=workload                        │
│  taint: app=workload:NoSchedule             │
│                                             │
│  SimpleTimeService pods only                │
└─────────────────────────────────────────────┘
```

All platform components (including Karpenter and Cluster Autoscaler themselves) run on core nodes via:
```yaml
nodeSelector:
  app: core
tolerations:
  - key: app
    operator: Equal
    value: core
    effect: NoSchedule
```

---

## Cluster Autoscaler

Scales the **core managed node group** based on unschedulable pods. Uses auto-discovery via the `k8s.io/cluster-autoscaler/<cluster-name>` tag on the node group (set by `add_cluster_autoscaler_tags = true` in Terraform).

| Setting | Value |
|---------|-------|
| Chart | `cluster-autoscaler` v9.50.1 |
| Image | `v1.33.0` |
| Cloud provider | `aws` |
| Expander | `least-waste` |
| IRSA | `<cluster-name>-cluster-autoscaler-irsa` |

Key flags:

| Flag | Value | Reason |
|------|-------|--------|
| `balance-similar-node-groups` | `true` | Distributes nodes evenly across AZs |
| `skip-nodes-with-local-storage` | `false` | Allows scale-down of nodes with emptyDir volumes |
| `skip-nodes-with-system-pods` | `false` | Allows scale-down of nodes with DaemonSet pods |

Verify it is running and watching the node group:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50
```

---

## Karpenter

Provisions **workload nodes** on demand when pods with `nodeSelector: {app: workload}` are unschedulable. Uses EKS Pod Identity (not IRSA) for the controller, and a dedicated instance profile for nodes.

### Controller

| Setting | Value |
|---------|-------|
| Chart | `karpenter` v1.0.8 (from `public.ecr.aws/karpenter`) |
| Interruption queue | `<cluster-name>-karpenter-interruption` (SQS) |
| Pod Identity | Configured by Terraform, not IRSA |

### Interruption handling

Karpenter watches an SQS queue for EC2 lifecycle events and proactively drains affected nodes before they terminate, giving workloads time to reschedule gracefully.

The queue and EventBridge rules are created by Terraform via `enable_spot_termination = true` in `terraform/karpenter.tf`. Despite the flag name, the rules cover all capacity types - not just spot:

| EventBridge rule | Applies to | What Karpenter does |
|-----------------|------------|---------------------|
| EC2 Spot Instance Interruption Warning | Spot nodes | Cordons and drains node 2 minutes before termination |
| EC2 Rebalance Recommendation | Spot + on-demand | Voluntarily replaces the node to improve availability |
| EC2 Instance State-change Notification | All nodes | Detects unexpected stops/terminations and cleans up |
| AWS Health Events (scheduled maintenance / retirement) | All nodes | Drains node ahead of the maintenance window |

Since this cluster uses **on-demand only**, spot interruptions never fire - but rebalance recommendations, state-change notifications, and AWS Health retirement events all apply and are actively handled.

The queue name is injected into the Karpenter Helm release at deploy time from the ArgoCD cluster secret annotation `cluster-name`:

```yaml
settings:
  interruptionQueue: "<cluster-name>-karpenter-interruption"
```

Verify the queue exists and EventBridge rules are wired up:

```bash
aws sqs get-queue-url --queue-name <cluster-name>-karpenter-interruption
aws events list-rules --name-prefix "karpenter" --query "Rules[].Name"
```

### NodePool and EC2NodeClass

Applied at sync-wave 4 (after the controller at wave 3). The instance profile name is injected at deploy time from the ArgoCD cluster secret annotation `karpenter-instance-profile-name`.

| Setting | Value |
|---------|-------|
| AMI family | AL2023 |
| AMI alias | `al2023@v20260415` |
| Instance types | `t3a.medium`, `c6a.large` |
| Capacity type | on-demand |
| Node expiry | 720h (30 days) |
| Consolidation | `WhenEmptyOrUnderutilized`, 5-minute delay |
| Consolidation budget | max 20% of nodes disrupted at once |
| Pool limits | 100 vCPU / 200 GiB memory |

Nodes are tainted `app=workload:NoSchedule` and labeled `app=workload`. Only pods with the matching toleration and `nodeSelector: {app: workload}` land on these nodes.

Subnet and security group discovery uses the tag `karpenter.sh/discovery: <cluster-name>` (set on private subnets and the node security group by `enable_karpenter_discovery_tags = true` in Terraform).

Verify nodes are provisioned when workload pods are scheduled:

```bash
kubectl get nodeclaims
kubectl get nodes -l app=workload
kubectl get nodepool workload
kubectl get ec2nodeclass workload
```

---

## metrics-server

A hard prerequisite for HPA - without it the HPA controller cannot read pod CPU/memory utilization and no scaling decisions are made.

| Setting | Value |
|---------|-------|
| Chart | `metrics-server` v3.12.2 |
| Namespace | `kube-system` |

Two flags are required for EKS compatibility:

| Flag | Reason |
|------|--------|
| `--kubelet-preferred-address-types=InternalIP` | EKS node hostnames are not DNS-resolvable inside the cluster |
| `--kubelet-insecure-tls` | Skips kubelet TLS verification (acceptable for demos) |

Verify it is serving metrics:

```bash
kubectl top nodes
kubectl top pods -n simple-time-service
```

---

## HPA

The `simple-time-service` HPA is defined in [charts/simple-time-service/templates/hpa.yaml](../../charts/simple-time-service/templates/hpa.yaml) and **disabled by default** in `values.yaml`. It is enabled via an override in the ApplicationSet:

```yaml
hpa:
  enabled: true
```

| Setting | Value |
|---------|-------|
| Target metric | Average CPU utilization |
| Target value | 70% |
| Min replicas | 2 |
| Max replicas | 10 |
| Scale-up | 2 pods per 30s, no stabilization delay |
| Scale-down | 1 pod per minute, 5-minute stabilization window |

The conservative scale-down window prevents thrashing under bursty traffic.

Watch the HPA respond to load:

```bash
# Terminal 1 - generate load
python3 scripts/load_test.py --url https://simple-time-service.platform.<your-domain>/

# Terminal 2 - watch HPA
kubectl get hpa -n simple-time-service -w

# Terminal 3 - watch pods
kubectl get pods -n simple-time-service -w
```

Current HPA status:

```bash
kubectl describe hpa simple-time-service -n simple-time-service
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `namespace kube-node-lease is not permitted in project 'platform'` on Karpenter sync | Karpenter creates a `RoleBinding` in the `kube-node-lease` namespace so it can delete node `Lease` objects when it terminates nodes. The `platform` AppProject must include `kube-node-lease` as a destination (`gitops/argocd/projects/platform-project.yaml`). |
| Karpenter nodes not provisioning | Check Karpenter controller logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`. Common causes: Pod Identity not configured, interruption queue name mismatch, or missing `karpenter.sh/discovery` tag on subnets/security groups. |
| Nodes provisioned but pods not scheduled | Confirm the pod has both the matching `nodeSelector: {app: workload}` and the `app=workload:NoSchedule` toleration. Karpenter only provisions for pods it can actually schedule. |
