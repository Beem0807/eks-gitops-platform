# Cost

Running this stack continuously costs roughly **$310–330/month** at idle (on-demand, ap-south-1). Under active load (HPA scale-outs, load tests, Karpenter provisioning) expect **$400–500/month**.

Tear down the cluster when not in use. At rest, only S3, Route 53, and Secrets Manager accrue charges - under $10/month total.

---

## Monthly estimate (on-demand, ap-south-1, idle)

| Component | Configuration | Estimate |
|-----------|--------------|----------|
| EKS control plane | 1 cluster | ~$73 |
| Managed node group | 2× `m6a.large` | ~$126 |
| Karpenter workload nodes | avg 1× `t3a.medium` | ~$28 |
| NAT Gateway | 1 gateway + minimal data transfer | ~$38 |
| Application Load Balancers | 2 ALBs (ArgoCD + Grafana/app) | ~$43 |
| EBS volumes | Prometheus 50 GB + Thanos 20 GB (`gp3`) | ~$7 |
| S3 | Loki logs, Thanos blocks, Velero backups, Tempo traces | ~$3–6 |
| Secrets Manager | ~5 secrets | ~$2 |
| Route 53 | 1 hosted zone | ~$1 |
| Crossplane | core + RBAC manager + 4 provider pods, on existing core nodes | ~$0 |
| Actions Runner Controller | controller + idle scale set listener, on existing core nodes | ~$0 |
| **Total** | | **~$320–325/month** |

Crossplane and ARC add no new billable AWS resources. Both run as pods on the existing managed node group and add roughly 1.0–1.3 GB of memory requests and 0.5 vCPU across six pods - absorbed by the two `m6a.large` core nodes without extra capacity.

They do create cost *indirectly*, which is the part worth watching:

| Source | Why |
|--------|-----|
| Crossplane-provisioned resources | A consuming project can create S3 buckets, ECR repositories, and SQS queues on demand. ML datasets and container images are the two largest line items in practice - a single CUDA-based training image can exceed 10 GB |
| Runner pods | Each in-progress CI job is a runner pod plus a BuildKit sidecar, requesting 1 vCPU / 2 GiB combined. They are scheduled onto Karpenter `app=workload` nodes, so concurrent builds provision nodes - up to `maxRunners: 5`, roughly 5 vCPU / 10 GiB at full tilt. `minRunners: 0` means nothing idles between jobs |

Neither is billed until a consuming project actually uses it. An EKS-only deployment pays nothing extra.

Prices are approximate. Use the [AWS Pricing Calculator](https://calculator.aws/) for an exact figure based on your region and usage.

---

## Watching Crossplane-provisioned spend

Resources created through Crossplane are not in Terraform state, so `terraform destroy` will not remove them and they do not appear in a Terraform plan. List them from the cluster:

```bash
kubectl get managed
```

[examples/crossplane/](../examples/crossplane/) sets lifecycle rules on both the S3 and ECR examples for this reason - expiring superseded object versions, aborting incomplete multipart uploads (which accrue storage charges without appearing in an object listing at all), and capping retained image counts. None of that is enforced by the platform, so it has to be in the manifests.

---

## Cost-control mode

Apply these when you want to keep the cluster running but minimise spend:

| Change | Monthly saving | Trade-off |
|--------|---------------|-----------|
| Delete idle Karpenter nodes (`kubectl delete node`) when not testing | ~$28 | Workloads won't schedule until a new node is provisioned (~60 s) |
| Use Spot for Karpenter `NodePool` (`capacity-type: spot`) | ~$17–20 | Nodes can be reclaimed with 2-minute notice; acceptable for stateless demo workloads |
| Consolidate all ingresses onto a single ALB using AWS LBC `IngressGroup` | ~$20 | Requires adding `alb.ingress.kubernetes.io/group.name` annotation to all Ingress resources |
| Reduce managed node group to 1 node | ~$30 | No node redundancy; a single node issue takes down all system components |
| Drop Thanos and run Prometheus with short retention (2 weeks) | ~$5–10 | No long-term metric history |
| Reduce Prometheus EBS volume to 20 GB | ~$2 | Less scrape history before data rolls off |

---

## Teardown

Use the cleanup script - do not run `terraform destroy` directly. The script deletes Kubernetes Ingresses and LoadBalancer Services first (releasing ALBs and EBS volumes), then runs `terraform destroy`, then cleans up any remaining VPC dependencies (NAT Gateways, Internet Gateway, subnets) that Terraform cannot remove on its own.

```bash
cd terraform
./scripts/cleanup.sh
```

See [terraform/README.md](../terraform/README.md) for full teardown instructions and what the script does at each step.
