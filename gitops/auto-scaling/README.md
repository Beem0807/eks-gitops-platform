# Autoscaling

The `gitops/auto-scaling/` directory deploys five ArgoCD apps that together handle node, pod, and event-driven scaling.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `cluster-autoscaler/cluster-autoscaler.yaml` | Cluster Autoscaler v1.33.0 - scales the core managed node group | 1 | `kube-system` |
| `karpenter/karpenter.yaml` | Karpenter v1.0.8 controller - provisions workload nodes on demand | 3 | `karpenter` |
| `karpenter/karpenter-nodepools.yaml` | `EC2NodeClass` + `NodePool` for workload nodes | 4 | `karpenter` |
| `metrics-server/metrics-server.yaml` | metrics-server v3.12.2 - CPU/memory metrics API required by HPA | — | `kube-system` |
| `keda/keda.yaml` | KEDA v2.21.0 - event-driven scaling, including scale-to-zero | 11 | `keda` |

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

## KEDA

Covers the one case neither the HPA nor Karpenter can: **scaling to and from
zero based on an external event source**. An HPA needs a metric from a running
pod, so it cannot scale a workload that should have no pods at all; Karpenter
scales nodes in response to pods, not pods in response to work.

| Setting | Value |
|---------|-------|
| Chart | `keda` v2.21.0 (from `https://kedacore.github.io/charts`) |
| Namespace | `keda` |
| Components | operator, metrics API server, admission webhooks |
| Identity | EKS Pod Identity on the `keda-operator` ServiceAccount |
| IAM | `<cluster-name>-keda-operator` - `sqs:GetQueueAttributes` only |

### What it scales

Nothing, in an EKS-only cluster. The controller is installed everywhere because
event-driven autoscaling is a platform capability - the same argument that puts
Karpenter here - but the `ScaledObject` and `ScaledJob` resources that use it
belong to the workloads being scaled, in their own repositories.

The MLOps platform uses it for dataset ingestion: a `ScaledJob` in
`mlops-system` watches the `fraud-detection-ingestion` SQS queue and creates a
Job when a dataset is uploaded. Datasets arrive days or weeks apart, so steady
state is zero pods.

### Why not a CronJob

A CronJob costs nothing while idle, but its pickup latency is its schedule
interval. KEDA's is its polling interval:

| Approach | Idle cost | Pickup latency |
|----------|-----------|----------------|
| Deployment with a poll loop | a pod, and the node it blocks from consolidation | seconds |
| CronJob every 15m | a pod start every 15 minutes | up to 15 minutes |
| KEDA `ScaledJob` | nothing | ~30s (the polling interval) |

The middle column is why the Deployment loses: a pod idling for a week pins a
node that Karpenter would otherwise consolidate away, so the cost of waiting is
a node rather than a pod.

### IAM scope

The operator role reads queue depth and nothing else - no `ReceiveMessage`, no
`DeleteMessage`. The workload's own role does that, and the workload is what the
Job runs as. The resource list is the two fraud-detection queues by ARN rather
than `*`, so a `ScaledObject` in any namespace cannot be used to enumerate the
depth of unrelated queues, including Karpenter's interruption queue.

Credentials come from Pod Identity, so the chart's ServiceAccount carries **no**
`eks.amazonaws.com/role-arn` annotation. The association is made in
`terraform/keda.tf` against the ServiceAccount *name*, which is why
`serviceAccount.name` is pinned in the Helm values and must not be overridden.

### The scaler gotcha worth knowing

The AWS SQS scaler's `scaleOnInFlight` defaults to **`true`**, which counts
in-flight (invisible) messages toward queue depth. For a `ScaledJob` that is
usually wrong: a message stays invisible for the whole visibility timeout while
its Job processes it, so KEDA keeps seeing depth >= 1 and starts another Job on
top of the one already running. Any consumer whose work must not overlap needs
`scaleOnInFlight: "false"`.

Verify the controller is up and a scaler is registered:

```bash
kubectl get pods -n keda
kubectl get scaledjobs,scaledobjects -A
kubectl describe scaledjob fraud-detection-ingestion -n mlops-system
```

If a scaler is not polling, the operator logs name the reason:

```bash
kubectl logs -n keda -l app.kubernetes.io/name=keda-operator --tail=100
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
| KEDA scaler reports an AWS auth error | The Pod Identity association in `terraform/keda.tf` names the `keda-operator` ServiceAccount. If `serviceAccount.name` was overridden in the Helm values, the association points at a ServiceAccount that does not exist and no credentials are injected - with no error at apply time. |
| A second ingestion Job starts while one is already running | `scaleOnInFlight` is defaulting to `true`. Set it to `"false"` on the trigger. |
| `namespace kube-node-lease is not permitted in project 'platform'` on Karpenter sync | Karpenter creates a `RoleBinding` in the `kube-node-lease` namespace so it can delete node `Lease` objects when it terminates nodes. The `platform` AppProject must include `kube-node-lease` as a destination (`gitops/argocd/projects/platform-project.yaml`). |

For operational incidents see the runbooks:

| Symptom | Runbook |
|---------|---------|
| Karpenter not provisioning nodes - Pod Identity, NodePool limits, subnet/SG tags | [karpenter-node-not-provisioning.md](../../docs/runbooks/karpenter-node-not-provisioning.md) |
| Nodes provisioned but pods not scheduled (taint/toleration mismatch) | [karpenter-node-not-provisioning.md](../../docs/runbooks/karpenter-node-not-provisioning.md) |
| HPA not scaling / metrics-server unavailable | [hpa-not-scaling.md](../../docs/runbooks/hpa-not-scaling.md) |
