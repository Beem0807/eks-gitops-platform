# Design Decisions

This document captures the "why" behind key architectural choices in this platform. Each decision records what was chosen, what was considered, and the reasoning - so future maintainers don't have to reverse-engineer intent from config.

---

## 1. ArgoCD App-of-Apps Instead of ApplicationSet-only Root

**Decision:** The bootstrap entry point is a single root `Application` ([gitops/bootstrap/root-app.yaml](../gitops/bootstrap/root-app.yaml)) that recursively syncs the `gitops/` directory. Each subsystem then uses an `ApplicationSet` for multi-cluster templating.

**Alternatives considered:**
- A single `ApplicationSet` at the root that generates all child apps directly.
- A flat list of manually maintained `Application` resources.

**Why this approach:**

The root `Application` acts as a stable, cluster-scoped anchor that bootstraps itself once and then self-heals. It requires no cluster metadata to function - you can apply it to a fresh cluster with `kubectl apply` and it takes over from there.

`ApplicationSet` resources, by contrast, are powerful for generating apps dynamically from cluster metadata, but they depend on a generator (cluster list, git, matrix) being available and healthy. Using one as the root creates a circular dependency: the ApplicationSet controller must already be running and aware of all target clusters before it can generate the apps that configure those clusters.

The hybrid model gives the best of both: a simple, unconditional root that always works, and `ApplicationSet` resources underneath for the multi-cluster templating that actually benefits from dynamic generation.

---

## 2. Cluster Autoscaler + Karpenter Together

**Decision:** Both Cluster Autoscaler ([gitops/auto-scaling/cluster-autoscaler/](../gitops/auto-scaling/cluster-autoscaler/)) and Karpenter ([gitops/auto-scaling/karpenter/](../gitops/auto-scaling/karpenter/)) are deployed on the same cluster.

**Alternatives considered:**
- Karpenter only.
- Cluster Autoscaler only.

**Why both:**

Karpenter and Cluster Autoscaler operate at different levels of the scaling stack and do not conflict when configured correctly.

**Cluster Autoscaler** manages the existing managed node groups defined in the EKS cluster. It responds to unschedulable pods by scaling those groups up, and drains and removes underutilized nodes. It is tightly coupled to AWS Auto Scaling Groups and is the correct tool for workloads pinned to specific node groups (e.g., system components, stateful workloads with node affinity).

**Karpenter** provisions entirely new nodes outside of any pre-defined node group, matching the exact resource shape a pending pod needs. It responds faster (seconds vs. minutes), bin-packs more efficiently, and handles spot interruption natively via the interruption queue.

In practice, Karpenter handles the fast, flexible scaling for application workloads while Cluster Autoscaler manages baseline capacity and provides a safety net for node groups that Karpenter does not own. The `NodePool` config in [gitops/auto-scaling/karpenter/karpenter-nodepools.yaml](../gitops/auto-scaling/karpenter/karpenter-nodepools.yaml) scopes Karpenter's provisioning so it does not interfere with managed node groups.

---

## 3. Prometheus + Thanos Instead of Amazon Managed Prometheus (AMP)

**Decision:** Self-managed Prometheus ([gitops/monitoring/prometheus/](../gitops/monitoring/prometheus/)) with Thanos ([gitops/monitoring/thanos/](../gitops/monitoring/thanos/)) for long-term storage, instead of delegating to AMP.

**Alternatives considered:**
- Amazon Managed Prometheus (AMP) with ADOT or remote_write.
- Victoria Metrics.

**Why Prometheus + Thanos:**

**Control and portability.** The full kube-prometheus-stack ships Alertmanager, recording rules, and dashboards as code in the same GitOps repo. Migrating to another cloud or self-hosted Kubernetes requires zero metric-layer changes.

**Cost model.** AMP charges per sample ingested and per query. At the cardinality this platform generates, S3 storage via Thanos is materially cheaper. Thanos compaction with tiered downsampling (raw 30d → 5m 90d → 1h 180d, configured in [gitops/monitoring/thanos/thanos.yaml](../gitops/monitoring/thanos/thanos.yaml)) keeps S3 costs low without losing historical resolution.

**Query federation.** Thanos Query aggregates across Prometheus sidecars and the StoreGateway in a single endpoint. Grafana points to Thanos as its primary datasource, so dashboards transparently cover both live (7-day local retention) and historical data without any dashboard changes.

**AMP limitations.** AMP does not support Alertmanager natively - you still need a self-managed Alertmanager. Running half the stack managed and half self-managed adds complexity without proportional benefit.

---

## 4. Loki SingleBinary Mode for This Deployment

**Decision:** Loki runs in `SingleBinary` mode with replication factor 1 ([gitops/logs/loki/loki.yaml](../gitops/logs/loki/loki.yaml)).

**Alternatives considered:**
- Loki Distributed (microservices mode).
- Loki SimpleScalable (read/write split).

**Why SingleBinary here:**

SingleBinary collapses all Loki components (ingester, querier, compactor, ruler) into a single process. For a demonstration or development cluster this dramatically reduces resource overhead, operational surface area, and Helm value complexity.

**What changes for production:**

| Concern | SingleBinary | Production |
|---|---|---|
| Replication | 1 (no HA) | ≥ 2 (SimpleScalable) or ≥ 3 (Distributed) |
| Ingester availability | Single point of failure | Multiple ingesters with WAL replication |
| Query scalability | Single process | Separate querier pool, query-frontend |
| Write scalability | Single process | Separate distributor/ingester pools |
| Local storage | `emptyDir` (lost on restart) | Persistent volumes or pure S3 |

The S3 backend is already configured (chunks, ruler, and admin all point to `lokiBucketName`), so migrating to SimpleScalable is a Helm values change - no data migration required. The TSDB schema with index in S3 is compatible across all deployment modes.

---

## 5. Kyverno in Audit Mode First

**Decision:** All four Kyverno policies (resource limits, privileged containers, latest image tag, non-root user) are set to `validationFailureAction: Audit` in [gitops/security/kyverno/kyverno-policies.yaml](../gitops/security/kyverno/kyverno-policies.yaml).

**Alternatives considered:**
- Enforce from day one.
- No admission control initially.

**Why audit first:**

Switching a policy from `Audit` to `Enforce` is a one-line change. The reverse - discovering that enforced policies are silently breaking workloads - requires incident response.

Audit mode lets Policy Reporter ([gitops/security/kyverno/policy-reporter.yaml](../gitops/security/kyverno/policy-reporter.yaml)) surface every violation across the cluster without blocking any deployment. This creates a complete violation inventory before enforcement begins, so each policy can be moved to `Enforce` only after:

1. All existing violating workloads are remediated or explicitly exempted.
2. The engineering team understands the policy scope.
3. CD pipelines are updated to validate compliance pre-deploy.

Audit also means the Kyverno admission controller itself is not a critical path for cluster bootstrapping - a Kyverno outage during initial platform setup cannot block system component pods from starting.

---

## 6. Public Grafana, Private Prometheus and Alertmanager

**Decision:** Grafana is exposed via an internet-facing ALB at `grafana.platform.<domain>`. Prometheus and Alertmanager have `ingress.enabled: false` and are accessible only within the cluster.

**Why Grafana is public:**

Grafana is the intended human interface for metrics and logs. It has its own authentication layer (credentials in AWS Secrets Manager, mounted via ExternalSecrets) and is the only surface that needs to be accessible to users without kubectl access.

**Why Prometheus and Alertmanager are private:**

Prometheus exposes the full metric scrape output, including internal service metadata, performance counters, and potentially sensitive labels. It has no built-in authentication. Exposing it publicly would reveal cluster topology and application internals to anyone who finds the endpoint.

Alertmanager's API allows silencing, inhibition, and route manipulation - effectively letting an unauthenticated caller suppress alerts. Keeping it private removes this attack surface.

Both are reachable from Grafana internally (`prometheus-operated.monitoring.svc.cluster.local`, `alertmanager-operated.monitoring.svc.cluster.local`), which is the only access they need. Any operator who needs direct Prometheus or Alertmanager access can use `kubectl port-forward`.

---

## 7. Retain Reclaim Policy for EBS PVCs

**Decision:** The `gp3` StorageClass sets `reclaimPolicy: Retain` ([gitops/storage/ebs-csi-driver/ebs-csi-driver.yaml](../gitops/storage/ebs-csi-driver/ebs-csi-driver.yaml)).

**Alternatives considered:**
- `reclaimPolicy: Delete` (Kubernetes default).

**Why Retain:**

`Delete` automatically destroys the EBS volume when the PVC is deleted. A misconfigured ArgoCD sync with `prune: true`, an accidental `kubectl delete pvc`, or a failed Helm upgrade rollback can permanently destroy the data on disk. For Prometheus (20Gi of metrics), AlertManager (2Gi of state), Thanos compactor (10Gi), and StoreGateway (5Gi), this data is not trivially reconstructable.

With `Retain`, the EBS volume persists after PVC deletion and enters `Released` state. A human must explicitly delete the PV (and by extension the EBS volume) to destroy the data. This creates a mandatory manual checkpoint before permanent data loss.

The trade-off is that `Released` volumes must be manually reclaimed or re-bound. For a platform where PVC lifecycles are well-understood and controlled by GitOps, this is an acceptable operational overhead relative to the blast radius of silent data deletion.

---

## 8. gp3 as Default StorageClass

**Decision:** The EBS CSI driver creates a `gp3` StorageClass and marks it as the cluster default (`storageclass.kubernetes.io/is-default-class: "true"`).

**Alternatives considered:**
- `gp2` (prior AWS default).
- No cluster-level default (require explicit StorageClass on every PVC).

**Why gp3:**

`gp3` delivers 3,000 IOPS and 125 MB/s throughput as the baseline at no additional cost, without the burst credit model of `gp2`. For Prometheus write-heavy workloads (constant TSDB WAL writes) and Thanos compaction (intensive sequential I/O during compaction windows), predictable throughput matters more than burst capacity.

`gp3` is also cheaper per GB than `gp2` (roughly 20% lower) and allows IOPS and throughput to be scaled independently of disk size - important if a volume needs more I/O without provisioning a larger disk.

Setting it as the cluster default means any workload that does not explicitly request a StorageClass (including Helm charts that leave `storageClass: ""`) gets encrypted gp3 volumes automatically, which is the correct secure baseline.

---

## 9. S3-Backed Storage for Loki, Thanos, and Velero

**Decision:** All three long-term storage concerns - logs (Loki), metrics (Thanos), and backups (Velero) - are backed by dedicated S3 buckets, provisioned in Terraform ([terraform/loki.tf](../terraform/loki.tf), [terraform/thanos.tf](../terraform/thanos.tf), [terraform/velero.tf](../terraform/velero.tf)) and referenced via cluster annotations.

**Alternatives considered:**
- EBS-only storage (no S3).
- A single shared S3 bucket for all three systems.

**Why S3 for all three:**

**Durability.** S3 provides 11 nines of object durability, which no EBS volume configuration matches. For metrics history, log archives, and disaster recovery backups, S3 is the appropriate durability tier.

**Cost at scale.** EBS volumes are reserved capacity billed whether used or not. S3 is pay-per-byte with lifecycle policies that can automatically transition old data to Glacier. Thanos compaction downsampling further reduces storage costs over time.

**Decoupling from node lifecycle.** EBS volumes are availability-zone bound. Cluster rebuilds, AZ migrations, or node replacements cannot touch S3 data. Velero's entire value proposition depends on backup storage surviving cluster destruction - EBS cannot provide that.

**Why separate buckets:**

Separate buckets allow independent IAM policies scoped to each workload's IRSA role, independent lifecycle policies (Thanos needs tiered downsampling; Velero needs backup retention windows; Loki needs chunk expiry), and independent encryption/access audit trails. A single shared bucket would require prefix-based IAM policies that are harder to reason about and easier to misconfigure.

Bucket names flow into Helm values via ArgoCD cluster secret annotations - the mechanism is covered in [decision 21](#21-terraformgitops-boundary-and-cluster-annotation-bridge).

---

## 10. ArgoCD AppProject Scoping Per Concern

**Decision:** Every ApplicationSet is assigned to one of six AppProjects: `bootstrap`, `namespaces`, `platform`, `observability`, `security`, `workloads`. Each project restricts allowed source repos, destination namespaces, and permitted cluster-scoped resource kinds.

**Why not one project or no projects:**

Without AppProjects, every ArgoCD application has access to every namespace and can create any resource kind cluster-wide. A misconfigured - or malicious - ApplicationSet could deploy into `kube-system`, create `ClusterRole` bindings, or install CRDs it has no business touching.

Each project enforces a whitelist:
- `workloads` can only deploy into `simple-time-service` and cannot create cluster-scoped resources.
- `security` can create Kyverno CRDs and `ClusterPolicy` resources but cannot touch `monitoring` or `kube-system`.
- `platform` covers infrastructure components (networking, storage, secrets) but not workloads.

This means a drift in one project's manifests cannot cascade into another concern. Projects are applied by `bootstrap.sh` before the root app so they exist before ArgoCD performs its first sync; subsequent changes are reconciled via GitOps like everything else.

---

## 11. Core/Workload Node Split

**Decision:** The EKS managed node group nodes are tainted `app=core:NoSchedule` and run system components only. Karpenter provisions separate workload nodes tainted `app=workload:NoSchedule` for application pods.

**Alternatives considered:**
- Mixed placement with just resource requests/limits.
- Separate managed node groups per concern.

**Why a taint-based split:**

Resource requests and limits protect against CPU/memory exhaustion, but they do not protect against node-level failure modes: a pod in a crash loop consuming high I/O, a pod triggering OOM kills that destabilize the node's kubelet, or a noisy-neighbour workload saturating the network interface. These affect everything on the node regardless of resource limits.

Separating core (ArgoCD, Prometheus, Loki, Kyverno, ESO, ALB controller, ExternalDNS) onto dedicated nodes means a misbehaving application workload cannot destabilize the control-plane components that manage the cluster. If the application nodes go down or are scaled to zero, the core nodes continue operating - operators can still connect, ArgoCD continues reconciling, and Prometheus continues scraping.

The taint approach is also cheaper than separate managed node groups because Karpenter provisions workload nodes on-demand and terminates them when idle, whereas a separate managed node group always maintains a minimum count.

---

## 12. ArgoCD Self-Managed via Helm

**Decision:** ArgoCD is bootstrapped once by `bootstrap.sh` using `helm install`, then manages its own upgrades and configuration through the Git repo (`gitops/argocd/argocd.yaml`).

**Why self-managed:**

If ArgoCD's configuration (replica count, resource limits, OIDC settings, ingress, Helm values) lives outside Git, it drifts silently. Operators make changes via the UI or `helm upgrade` manually, and there is no audit trail or rollback path.

By pointing an ArgoCD `Application` at its own Helm release, every ArgoCD configuration change goes through the same PR review → merge → auto-sync workflow as any other platform component. Rolling back an ArgoCD misconfiguration is `git revert`.

The initial `helm install` in `bootstrap.sh` is the only manual step - it is unavoidable because the engine must be running before it can manage itself. After that, all ArgoCD changes are GitOps-native.

---

## 13. Prometheus Adapter for Custom-Metric HPA

**Decision:** Prometheus Adapter ([gitops/monitoring/prometheus/prometheus-adapter.yaml](../gitops/monitoring/prometheus/prometheus-adapter.yaml)) is deployed to bridge Prometheus metrics into the Kubernetes custom metrics API, enabling HPA rules based on arbitrary Prometheus queries.

**Why not CPU/memory HPA only:**

CPU and memory are lagging indicators. A service that is slow due to database contention or downstream API latency will show low CPU while users experience degraded responses. Prometheus exposes application-level metrics (request rate, latency, queue depth, error rate) that reflect actual load far earlier than CPU metrics do.

The Prometheus Adapter registers itself as a `custom.metrics.k8s.io` API server. Any `HorizontalPodAutoscaler` can then reference a Prometheus query as its scaling metric without any changes to the HPA controller or the application. The adapter runs with two replicas and a PodDisruptionBudget (`maxUnavailable: 1`) to ensure the custom metrics API remains available during rolling updates.

---

## 14. External Secrets Operator with AWS Secrets Manager and Tag-Based IAM Scoping

**Decision:** External Secrets Operator ([gitops/secrets/external-secrets/](../gitops/secrets/external-secrets/)) uses a single `ClusterSecretStore` backed by AWS Secrets Manager, with IRSA scoped to only secrets tagged `ExternalSecret=true`.

**Alternatives considered:**
- AWS Systems Manager Parameter Store.
- Namespace-scoped `SecretStore` per namespace.
- Vault.

**Why Secrets Manager over Parameter Store:**

Secrets Manager supports structured JSON values natively. A single secret can hold `{"adminUser": "...", "adminPassword": "..."}` and ESO can extract individual keys via `remoteRef.property`. Parameter Store stores flat strings, which would require one parameter per credential field and a more complex ExternalSecret spec.

Secrets Manager also has first-class rotation support, which is relevant for any future automated credential rotation.

**Why ClusterSecretStore:**

A `SecretStore` is namespace-scoped. Using one per namespace means duplicating the IRSA role binding and AWS authentication config across every namespace that needs secrets. A `ClusterSecretStore` centralizes the auth config once; RBAC controls which namespaces can create `ExternalSecret` resources that reference it. The result is simpler ops without weaker isolation.

**Why tag-based IAM scoping:**

The IRSA policy grants `secretsmanager:GetSecretValue` only on secrets tagged `ExternalSecret=true`. This means the ESO service account cannot read arbitrary secrets in the AWS account - only secrets explicitly opted in to GitOps-managed syncing. If ESO's credentials were compromised, the blast radius is bounded to the tagged set.

**Refresh interval:**

All ExternalSecrets use a 1-hour refresh interval. This is conservative - short enough to pick up manual rotations within an hour, long enough to avoid hammering the Secrets Manager API. For emergency rotation, the `kubectl annotate externalsecret ... force-sync=$(date +%s)` pattern triggers an immediate resync.

---

## 15. Reloader Alongside External Secrets Operator

**Decision:** Reloader ([gitops/secrets/reloader/](../gitops/secrets/reloader/)) runs cluster-wide with annotation-based opt-in, and is used alongside ESO on Deployments that mount ExternalSecret-managed secrets.

**Why Reloader is necessary:**

ESO pulls a secret from Secrets Manager and writes it into a Kubernetes `Secret` object. That's all it does - it does not restart pods. Kubernetes itself does not restart pods when a mounted `Secret` changes (when mounted as a volume, the file is eventually updated in-place, but environment variables sourced from secrets require a pod restart to pick up new values).

Without Reloader, credential rotation is: rotate in Secrets Manager → ESO syncs after up to 1 hour → pod continues using the old value until its next restart. With Reloader, the chain is: ESO syncs → Reloader detects the Secret change → rolling restart is triggered automatically. This creates a zero-downtime rotation pipeline with no manual intervention.

**Why annotation-based opt-in:**

Reloader is configured with `watchGlobally: true` but only acts on Deployments annotated with `reloader.stakater.com/auto: "true"` or `reloader.stakater.com/reload: "<secret-name>"`. This prevents inadvertent restarts of system components that happen to mount secrets but are not designed for frequent rolling updates. Only workloads that explicitly opt in (Grafana, ArgoCD, Alertmanager) are restarted on secret rotation.

---

## 16. AWS Load Balancer Controller Instead of NGINX Ingress

**Decision:** All cluster ingress traffic is handled by the AWS Load Balancer Controller ([gitops/networking/ingress-controller/](../gitops/networking/ingress-controller/)) using `ingressClassName: alb`. No NGINX Ingress Controller is deployed.

**Alternatives considered:**
- NGINX Ingress Controller (cloud-agnostic).
- Traefik.

**Why ALB Controller:**

On EKS, the ALB Controller provisions an AWS Application Load Balancer per Ingress group, integrating natively with ACM for TLS, Route53 via ExternalDNS, and IAM via IRSA. There is no in-cluster proxy process to size, tune, or keep alive - the load balancer is fully managed AWS infrastructure.

`target-type: ip` routes directly from the ALB to pod IPs via the VPC CNI. This eliminates the extra hop through a node's iptables/IPVS rules that NGINX's `NodePort` mode requires, reducing latency and simplifying network path debugging.

**ALB sharing via `group.name`:**

Multiple Ingress resources in the same group share a single ALB. The `platform-observability` group consolidates Grafana (and any future monitoring UIs) onto one load balancer, reducing the per-ALB cost and the number of DNS entries to manage.

**Sync wave consideration:**

The ALB Controller is deployed at sync wave 2. ALB Ingress resources are at wave 6 or later. This gap exists because the ALB Controller's admission webhook requires a self-signed CA cert to be propagated to the API server before any Ingress can be admitted. Applying Ingresses in the same wave as the controller causes admission failures that ArgoCD retries, but the gap eliminates the failure entirely.

---

## 17. ExternalDNS with `sync` Policy and TXT Ownership Records

**Decision:** ExternalDNS ([gitops/networking/external-dns/](../gitops/networking/external-dns/)) uses `--policy=sync` and sets `txtOwnerId` to the cluster name, scoped to public Route53 zones only.

**Alternatives considered:**
- `--policy=upsert-only` (create records but never delete).
- Manually managed DNS.

**Why `sync` over `upsert-only`:**

`upsert-only` leaves DNS records behind after an Ingress or Service is deleted. Over time this creates orphaned A/CNAME records pointing at load balancers that no longer exist, which wastes Route53 costs and can create domain squatting risk if a deleted subdomain is re-registered externally. `sync` deletes records when their source resource is deleted, keeping DNS state consistent with cluster state.

**Why `txtOwnerId`:**

ExternalDNS writes a TXT record alongside every DNS record it manages, encoding the owner cluster name. When multiple clusters manage the same hosted zone, the TXT record prevents a cluster from modifying or deleting records it doesn't own. Without this, a second cluster applying ExternalDNS could overwrite DNS records created by the first.

**Public zones only:**

`--aws-zone-type=public` restricts ExternalDNS to public hosted zones. The platform's services that need DNS (Grafana, ArgoCD, application endpoints) are all intentionally internet-facing. Restricting to public zones prevents accidental modification of any private hosted zones used for internal service discovery.

---

## 18. ArgoCD Sync Wave Ordering

**Decision:** Resources across the platform are assigned explicit sync waves (`argocd.argoproj.io/sync-wave`) ranging from `-1` to `10`, following a strict dependency ordering.

**Why explicit waves are necessary:**

ArgoCD applies all resources in a sync together by default. Without waves, a `PrometheusRule` CRD and a `PrometheusRule` instance could be applied simultaneously - the instance fails because the CRD schema isn't registered yet. Waves enforce a sequenced rollout where each wave must be healthy before the next begins.

**Wave assignments and their rationale:**

| Wave | What | Why first |
|---|---|---|
| -1 | Namespaces | Must exist before any workload targets them |
| 0 | Prometheus CRDs | Schema must be registered before the kube-prometheus-stack creates CRD instances |
| 1 | EBS CSI, ESO, Reloader, Cluster Autoscaler | Storage and secrets infrastructure must be ready before anything else runs |
| 2 | ALB Controller, ExternalDNS | Networking must be ready before any Ingress is created; ALB webhook needs time to initialize |
| 3 | Karpenter, Velero, Kyverno | Controllers before their CRD instances (NodePools, Schedules, ClusterPolicies) |
| 4 | Karpenter NodePools, ClusterSecretStore | NodePools after Karpenter is running; ClusterSecretStore after ESO is ready |
| 5 | All ExternalSecrets, Kyverno policies | Secrets before consumers; policies before workloads |
| 6–8 | Loki, Prometheus, Grafana, workloads | Observability stack before application workloads |
| 9–10 | Prometheus Adapter, AlertManager config, Thanos | Depends on Prometheus sidecar being live |

The wave 2 → wave 6 gap for ALB Ingress resources is explained in [decision 16](#16-aws-load-balancer-controller-instead-of-nginx-ingress).

---

## 19. Fluent Bit Instead of Fluentd

**Decision:** Log collection uses Fluent Bit ([gitops/logs/fluent-bit/](../gitops/logs/fluent-bit/)) as a DaemonSet, not Fluentd.

**Why Fluent Bit:**

Fluent Bit is written in C; Fluentd is written in Ruby. On a per-node DaemonSet that runs on every node in the cluster, this difference matters: Fluent Bit uses roughly 450 KB of memory at idle versus Fluentd's ~40 MB. At scale, that difference is multiplied by every node.

Fluent Bit also starts faster (no Ruby VM warmup), which matters during node turnover - Karpenter provisions new nodes frequently, and a slow-starting log agent means a window of dropped logs per node launch.

The native Loki output plugin in Fluent Bit is stable, well-tested, and supports label injection directly from Kubernetes metadata. The Kubernetes filter plugin enriches every log line with `namespace`, `pod`, and `container` labels without any additional configuration, which maps directly to Loki's label-based indexing.

---

## 20. Velero Daily Backup at 02:00 UTC with 30-Day Retention

**Decision:** Velero ([gitops/backup/velero/](../gitops/backup/velero/)) runs a full-cluster backup daily at `0 2 * * *` UTC, retaining snapshots for 30 days with EBS volume snapshots enabled.

**Why 02:00 UTC:**

02:00 UTC falls in the low-traffic window for most global timezones (late night US, early morning EU, morning APAC). Backup operations involve EBS snapshot I/O and Kubernetes API list calls - scheduling during low-traffic periods minimizes interference with normal workload performance.

**Why all namespaces + cluster-scoped resources:**

`includedNamespaces: ["*"]` with `includeClusterResources: true` ensures a complete cluster recovery is possible from a single backup. Selective namespace backups reduce restore complexity but create gaps - a ClusterRole referenced by a namespace-scoped RoleBinding would be missing on restore if only namespace resources are included.

**Why EBS volume snapshots:**

Kubernetes manifest backups alone restore the PVC definition, but not the data on the volume. EBS snapshots run alongside the manifest backup, capturing the actual state of Prometheus, AlertManager, Thanos, and any other stateful workloads at the same point in time. Restore from a manifest-only backup would create empty PVCs, effectively losing all metrics history.

**Why 30 days:**

30 days covers most incident discovery windows - issues that require historical data recovery are typically identified within a month. Beyond 30 days, the cost of maintaining EBS snapshots (which cannot be downsampled like Thanos metrics) grows proportionally without meaningful additional recovery value.

---

## 21. Terraform/GitOps Boundary and Cluster Annotation Bridge

**Decision:** Terraform owns all AWS infrastructure (VPC, EKS, IAM, S3, Secrets Manager). GitOps owns all Kubernetes configuration. The boundary is bridged via ArgoCD cluster secret annotations, which inject Terraform outputs into ApplicationSet templates.

**Why a strict boundary:**

Terraform is designed for stateful AWS resource management: it tracks resource IDs, handles update/destroy lifecycles, and manages dependencies across AWS APIs. Kubernetes resources managed by Terraform drift from GitOps state - if ArgoCD reconciles a resource that Terraform also owns, the two systems fight.

Conversely, Kubernetes config (Helm values, Ingress rules, PrometheusRules) changes far more frequently than AWS infrastructure. Putting it in Terraform means a `terraform apply` cycle for every Helm values tweak - slow and operationally cumbersome.

**How the bridge works:**

After `terraform apply`, the bootstrap script writes a cluster secret into ArgoCD with annotations containing Terraform outputs: `vpcId`, `clusterName`, `region`, `accountId`, `thanosBucketName`, `lokiBucketName`, `veleroBucketName`, `domainName`, and IRSA role ARNs. ApplicationSet `clusterDecisionResource` generators read these annotations and inject them as template variables into every child Application's Helm values.

This means the GitOps manifests contain no hardcoded AWS account IDs, bucket names, or ARNs. The same manifests work across dev, staging, and production clusters by simply changing the cluster secret annotations - Terraform outputs flow automatically into all downstream Helm values without any manifest changes.

---

## Demo Trade-offs

The following are intentional shortcuts taken for a demonstration environment. Each entry notes what was simplified and what the production-ready alternative looks like.

**Single NAT gateway**
One NAT gateway serves all private subnets. This saves ~$33/month but creates a single point of failure - if the NAT gateway's AZ becomes unavailable, all private-subnet nodes lose outbound internet access. Production deployments should provision one NAT gateway per AZ.

**Public EKS API endpoint**
The Kubernetes API server is reachable from any IP. For demos this is acceptable; for production, restrict `public_access_cidrs` to known CIDR ranges (VPN, office) and consider enabling the private endpoint so in-cluster traffic stays within the VPC. Enable control plane audit logging for any environment with real workloads.

**Prometheus Operator TLS and webhooks disabled**
The kube-prometheus-stack is installed with `admissionWebhooks.enabled: false` and TLS between components disabled. This simplifies bootstrap reliability - self-signed cert generation and webhook registration can fail during initial cluster setup if the timing is wrong. Re-enable both for production; the admission webhooks validate `PrometheusRule` and `ServiceMonitor` resources and prevent misconfigured CRD instances from silently failing.

**Network Policy disabled by default**
The `simple-time-service` chart includes a `NetworkPolicy` resource but it is off by default, meaning there is no east-west traffic isolation between namespaces. Enabling it requires two steps: turning on the VPC CNI Network Policy controller in Terraform (`enable_network_policy: "true"` on the VPC CNI addon), then setting `networkPolicy.enabled: true` in the ApplicationSet. Without the CNI controller, `NetworkPolicy` resources are created but silently ignored.

**Prometheus and Alertmanager with no ingress**
Covered in [decision 6](#6-public-grafana-private-prometheus-and-alertmanager). For production, expose both behind an authentication proxy (e.g. `oauth2-proxy` with OIDC) rather than open ALB ingress, rather than relying on `kubectl port-forward` for operator access.
