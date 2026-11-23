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

## 9. S3-Backed Storage for Loki, Thanos, Velero, and Tempo

**Decision:** All four long-term storage concerns - logs (Loki), metrics (Thanos), backups (Velero), and traces (Tempo) - are backed by dedicated S3 buckets, provisioned in Terraform ([terraform/loki.tf](../terraform/loki.tf), [terraform/thanos.tf](../terraform/thanos.tf), [terraform/velero.tf](../terraform/velero.tf), [terraform/tempo.tf](../terraform/tempo.tf)) and referenced via cluster annotations.

**Alternatives considered:**
- EBS-only storage (no S3).
- A single shared S3 bucket for all three systems.

**Why S3 for all three:**

**Durability.** S3 provides 11 nines of object durability, which no EBS volume configuration matches. For metrics history, log archives, and disaster recovery backups, S3 is the appropriate durability tier.

**Cost at scale.** EBS volumes are reserved capacity billed whether used or not. S3 is pay-per-byte with lifecycle policies that can automatically transition old data to Glacier. Thanos compaction downsampling further reduces storage costs over time.

**Decoupling from node lifecycle.** EBS volumes are availability-zone bound. Cluster rebuilds, AZ migrations, or node replacements cannot touch S3 data. Velero's entire value proposition depends on backup storage surviving cluster destruction - EBS cannot provide that.

**Why separate buckets:**

Separate buckets allow independent IAM policies scoped to each workload's IRSA role, independent lifecycle policies (Thanos needs tiered downsampling; Velero needs backup retention windows; Loki needs chunk expiry; Tempo needs trace retention), and independent encryption/access audit trails. A single shared bucket would require prefix-based IAM policies that are harder to reason about and easier to misconfigure.

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
| 6–8 | Loki, Tempo, Prometheus, Grafana, workloads | Observability stack before application workloads |
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

After `terraform apply`, the bootstrap script writes a cluster secret into ArgoCD with annotations containing Terraform outputs: `vpcId`, `clusterName`, `region`, `accountId`, `thanosBucketName`, `lokiBucketName`, `veleroBucketName`, `tempoBucketName`, `domainName`, and IRSA role ARNs. ApplicationSet `clusterDecisionResource` generators read these annotations and inject them as template variables into every child Application's Helm values.

This means the GitOps manifests contain no hardcoded AWS account IDs, bucket names, or ARNs. The same manifests work across dev, staging, and production clusters by simply changing the cluster secret annotations - Terraform outputs flow automatically into all downstream Helm values without any manifest changes.

---

## 22. OTel Collector Two-Tier Topology (DaemonSet Agent + Deployment Gateway)

**Decision:** Traces are not exported directly from application pods to Tempo. Instead, a two-tier OpenTelemetry Collector pipeline sits between them: a DaemonSet agent on every node receives spans from local pods, and a central Deployment gateway batches and forwards to Tempo ([gitops/tracing/otel-collector/](../gitops/tracing/otel-collector/)).

**Alternatives considered:**
- App → Tempo directly (OTLP HTTP).
- App → single shared Collector Deployment (no DaemonSet).

**Why not direct to Tempo:**

Exporting directly couples every instrumented pod to Tempo's address, port, and availability. If Tempo is restarting, being upgraded, or temporarily unavailable, the application SDK's send buffer fills and spans are dropped unless retry/queue logic is explicitly configured in each application. Moving that concern to a collector process that runs independently of the application means the SDK can stay simple (fire-and-forget OTLP) and the collector handles retries, buffering, and backend routing.

Directly connecting also prevents any future enrichment or fanout without touching application code. Routing to a second backend (e.g. a vendor APM tool alongside Tempo) requires a collector in the path; retrofitting one later is harder than having it there from the start.

**Why a DaemonSet agent, not a single Deployment:**

A single shared Collector Deployment would mean every pod on every node sends spans over the network to a single pod on a different node. Under load, this concentrates both network traffic and resource pressure on one target. It also introduces a single point of failure for span collection - if the collector pod restarts, spans from the entire cluster queue or drop until it recovers.

The DaemonSet pattern keeps the first hop node-local: each pod sends spans to `$(status.hostIP):4318`, which is the agent running on the same physical node. No cross-node traffic is incurred for span ingestion. The agent is small (50m CPU / 128Mi memory) and runs a short-lived buffer with a 200ms batch window before forwarding gRPC to the gateway.

**Why still have a central gateway:**

The agent is intentionally thin - short buffers, fast batching, minimal processing. Centralising durable buffering, larger batches (1s / 1000 spans), and the Tempo export in a single gateway pod means:

- The agent failure domain is scoped to one node. If it crashes, only pods on that node are affected until it restarts (typically seconds on a DaemonSet).
- The gateway is the single point that speaks to Tempo. Tempo connection details, TLS config, or backend changes only need to be updated in one place.
- Backpressure from Tempo (slow writes, storage pressure) is absorbed at the gateway, not propagated back to every node agent simultaneously.

**Trade-off:**

The two-tier setup adds a hop and two separate Helm releases to manage. For a single-node development cluster it is over-engineered. For a multi-node cluster where workload nodes turn over frequently (Karpenter), the DaemonSet's node-local placement and independent lifecycle justify the added complexity.

---

## 23. Direct Managed Resources Instead of Crossplane Compositions

**Chosen:** consuming projects write the AWS provider's managed resources directly (`Bucket`, `Repository`, `Queue`). No XRDs, no Compositions, no composition functions.

Crossplane's headline feature is the ability to define a custom API - an XRD such as `S3Bucket` - and have a Composition expand it into several underlying resources with platform defaults baked in. The platform publishes a narrow API, consumers fill in three fields, and settings the platform cares about are simply not expressible by the consumer.

That was built and then removed. The reasoning for dropping it:

- **The abstraction has to earn its indirection.** A Composition is a second schema to maintain, version, and debug. When a composed resource fails, the error is on the managed resource, which is one level removed from the manifest the author wrote - so diagnosing it means understanding both layers.
- **Crossplane 2.x removed inline patching.** `mode: Resources` no longer exists; the only Composition mode is `Pipeline`, which requires a composition function (`function-patch-and-transform`) as an additional package. Every field mapping becomes a `FromCompositeFieldPath` patch entry rather than a line of YAML, and anything involving a JSON string field or a cross-resource ARN needs a `CombineFromComposite` with a format string.
- **Consumers lose access to the full API.** Any field the XRD does not expose cannot be set. For S3 alone the provider offers 25 resource types; an XRD covering the useful subset is a large surface to design and a continuous source of "can you add this field" requests.

**Trade-off, stated plainly:** the platform's preferences are now conventions rather than guarantees. A manifest that sets `imageTagMutability: MUTABLE`, skips encryption on a queue, or omits a dead-letter queue will be accepted. [examples/crossplane/](../examples/crossplane/) documents the intended settings and the reasoning for each, and the API surface is deliberately bounded by the activation policy (decision #25), but nothing rejects a non-conforming manifest.

A Kyverno policy layer was also considered for enforcing these invariants at admission, and was not adopted. Worth noting for anyone revisiting this: enforcing with Kyverno *mutate* rules would conflict with ArgoCD. Every app in this repo syncs with `selfHeal: true`, so a field present on the live object but absent from Git reads as drift - ArgoCD reverts the mutation, the webhook reapplies it, and the Application never reaches Synced. Enforcement would have to be `validate` with `Enforce`, rejecting non-conforming manifests rather than fixing them.

What does remain enforced is IAM, which no manifest can talk its way around - see decision #24.

---

## 24. EKS Pod Identity for Crossplane, and Deny-Based IAM Scoping

**Chosen:** EKS Pod Identity for the Crossplane providers, one IAM role per AWS service, allowed account-wide within that service, with an explicit deny on everything Terraform provisions.

**Pod Identity rather than IRSA**, which is what every other workload in this platform uses. The reason is mechanical: the provider pods' ServiceAccounts are created by the Crossplane package manager, not by a Helm chart, so there is no chart value to attach an `eks.amazonaws.com/role-arn` annotation to. Pod Identity needs nothing on the Kubernetes object - the namespace/ServiceAccount to role mapping lives entirely in AWS. The Pod Identity agent addon was already installed and Karpenter already uses this mechanism.

This is what makes the `DeploymentRuntimeConfig` per provider load-bearing rather than cosmetic. A Pod Identity association names a fixed ServiceAccount, but the package manager derives the ServiceAccount name from the *provider revision* - so it changes on every provider upgrade, and AWS authentication would break silently each time. The runtime configs pin the names.

**One role per service.** `provider-aws-s3` holds no ECR or SQS permissions, and none of the three can reach IAM, EC2, or anything else. A compromised or misconfigured S3 provider cannot create an IAM role.

**Why the allow is broad.** Within its own service each role is allowed account-wide, with no name-prefix or tag condition. Both narrower options were evaluated and rejected:

- A **name prefix** condition would force a naming convention onto every consuming repository, and a resource named outside it fails with `AccessDenied` rather than a validation error.
- A **tag** condition is strictly worse without an enforcement layer. The AWS `ClusterProviderConfig` has no `default_tags` equivalent, so an ownership tag would have to be written by hand in every manifest. Omitting it produces the worst available failure mode: AWS creates the resource, then denies every subsequent read, update, and delete - leaving a managed resource that can neither reconcile nor be deleted. Tag-based ABAC is genuinely viable here (all three services support `aws:ResourceTag`, and S3 additionally exposes `s3:BucketTag`, which uniquely also covers object-level actions), but only alongside something that guarantees the tag.

**Why the deny is precise.** The protection runs in the other direction instead. Terraform stamps `CrossplaneAccess=deny` onto the Thanos, Loki, Velero, and Tempo buckets and the Karpenter interruption queue, and each policy carries a matching `Deny` statement. An explicit deny in IAM cannot be overridden by any allow in any policy, so no manifest can make these roles delete the metric store, the log store, the backup bucket, the trace store, or the queue Karpenter depends on for spot interruption handling. Protecting a new Terraform-created resource is one line: merge `local.crossplane_denied_tags` into its tags.

The S3 deny is keyed on `s3:BucketTag` rather than `aws:ResourceTag` specifically because it also applies to object-level actions. With `aws:ResourceTag`, `forceDestroy` could still empty a protected bucket.

**What remains reachable:** resources in the account carrying no `CrossplaneAccess` tag - anything created outside this repository. Closing that gap needs either an agreed naming convention or an enforced ownership tag.

**This reasoning assumes no org-level guardrail.** Keeping Crossplane out of IAM entirely is a consequence of there being no Service Control Policy or permissions boundary above this account to contain an escalation - not an inherent property of the design. See decision #29 for what changes when those exist.

---

## 25. Managed Resource Activation Instead of Installing Every CRD

**Chosen:** install Crossplane with `provider.defaultActivations: []` and activate three API groups by wildcard.

Crossplane 2.x only serves a provider's managed resource CRDs when a `ManagedResourceActivationPolicy` names them. The AWS provider family ships roughly **2,100** managed resource types. The Helm chart's default is `["*"]`, which activates all of them - a permanent cost in API server memory and one informer per type, for types nothing in this platform uses.

The policy activates `*.s3.aws.m.upbound.io`, `*.ecr.aws.m.upbound.io`, and `*.sqs.aws.m.upbound.io`: around 60 CRDs rather than 2,100, while still letting consuming projects use any resource type within those three services - including sub-resources like `BucketVersioning` and `LifecyclePolicy` - without a platform change.

Only the **namespaced** variants (`*.aws.m.upbound.io`) are activated; the cluster-scoped variants (`*.aws.upbound.io`) are left inactive. Every Crossplane resource therefore lives in a namespace and is governed by that namespace's RBAC, so granting a team the ability to provision a bucket is an ordinary namespaced RoleBinding.

This doubles as the real API boundary now that there is no Composition layer (decision #23): a consuming project cannot provision an RDS instance or an EC2 instance, because those CRDs are not served and the manifest fails with `no matches for kind`.

**Trade-off:** adding a fourth AWS service is three coordinated changes - install the provider package, grant it a role in `terraform/crossplane.tf`, and add its group to the activation policy. Miss the third and the symptom is a confusing `no matches for kind` on a provider that reports Healthy.

The namespaced API has a sharp edge worth recording: it models some nested blocks as single objects where the cluster-scoped API uses single-element arrays, inconsistently even within one resource - and almost every example online uses the cluster-scoped form. Kubernetes always validates field types, so a shape mismatch is rejected with a 400 and the Application goes `SyncFailed`; unknown fields are rejected the same way because ArgoCD sends `fieldValidation=Strict` by default. The one way to turn this into a silent failure is setting `Validate=false` in an Application's `syncOptions`, which switches ArgoCD to `fieldValidation=Ignore` - at which point a misspelled field is dropped and the resource reports Ready with the setting missing. Neither `kubeconform` nor `yamllint` covers the gap, because there is no public schema for the provider CRDs and kubeconform skips these resources entirely.

---

## 26. Actions Runner Controller - Both Halves Platform-Owned

**Chosen:** this repository installs the ARC controller *and* a general-purpose `platform-runners` scale set. Any repository in the organisation uses it with `runs-on: platform-runners`.

ARC splits into a controller that watches `AutoScalingRunnerSet` resources and a per-scale-set listener that polls GitHub for jobs. The controller is cluster-singleton infrastructure — it owns four cluster-scoped CRDs, so two installations would fight over them. That part was never in question.

The scale set is the interesting half. The obvious split is for each consuming project to own its own, since runner *shape* (image, resource limits, GPU) is workload-specific. That was the initial design and it was reversed, for three reasons:

**The chart hardcodes a platform internal.** The scale set chart creates a RoleBinding granting the controller access to the runners namespace, and by default discovers the controller's ServiceAccount with a Helm `lookup` against the live cluster. ArgoCD's repo-server renders charts **without** cluster access, so the lookup returns nil and the chart fails outright with `No gha-rs-controller deployment found`. The fix is pinning `controllerServiceAccount.name: arc-gha-rs-controller`, which is `<controller releaseName>-gha-rs-controller`. So *any* scale set, anywhere, must hardcode the name of the platform's controller Helm release — and renaming that release would silently break a chart in a different repository. That is a bad seam to run across a repository boundary.

**The credential and the AWS identity are already platform-side.** The GitHub App secret originates in AWS Secrets Manager, reachable only by the platform's `ClusterSecretStore` and the External Secrets IRSA role. The `arc-runner` ServiceAccount carries the ECR IRSA role from `terraform/arc-runner-irsa.tf`. Moving the consumer across the boundary would split three things that have to agree.

**It is a capability, not a workload.** One controller, one credential, one pool, any number of consuming repositories. A per-project scale set is the exception, not the pattern.

The namespace split is kept (`arc-systems` for the controller, `arc-runners` for scale sets) so a project that genuinely needs a different shape — GPU, much larger limits, a custom image — can deploy its own there without being granted anything over the controller. `gitops/ci/README.md` documents that path, including the `controllerServiceAccount` block, specifically so nobody has to rediscover the `lookup` failure.

**The scale set is gated on configuration, unlike everything else in this repo.** Its cluster generator selects on a second label, `github-runners: enabled`, which `bootstrap.sh` sets only when `github_config_url` is non-empty. This is necessary rather than tidy: an unconfigured *controller* is harmless because it connects to nothing, but an unconfigured *scale set* crash-loops its listener against the GitHub API forever. With the label absent the generator produces no Application at all — nothing to show Degraded, nothing to prune. Using the generator's own selector keeps this out of the deployment path entirely rather than introducing a deployment profile.

**A GitHub App rather than a PAT:** scoped to its installation, tokens short-lived and refreshed by the listener, not tied to a personal account. All four Terraform variables default to empty, so an EKS-only deployment applies cleanly and `bootstrap.sh` does not require them.

**Not using `containerMode: dind` or a mounted Docker socket.** The Docker socket is a root-equivalent interface to the node: a workflow that reaches it can start a privileged container, mount the host filesystem, and read every other pod's secrets. On a runner executing pull-request code that is cluster takeover, not a hardening nit. `dind` is the same exposure in a different shape — it needs a privileged container. The runner pod instead carries a rootless BuildKit sidecar on `tcp://localhost:1234`, which needs `Unconfined` seccomp and AppArmor because it uses user namespaces and overlayfs — a far narrower concession than privileged.

Runner pods land on Karpenter workload nodes rather than core nodes: a build that exhausts memory should take out a disposable workload node, not the one hosting ArgoCD and Prometheus. The BuildKit cache is an `emptyDir`, so it dies with the runner — a persistent cache would be faster but would carry state between jobs from different pull requests, which is what an ephemeral runner exists to prevent.

---

## 27. Optional MLOps Integration by Directory Location, Not a Feature Flag

**Chosen:** the MLOps ArgoCD Application lives in a top-level `optional/` directory, outside the tree the root app reads, and is enabled with `kubectl apply`.

The root Application syncs `path: gitops` with `directory.recurse: true`. Inclusion is therefore a property of **where a file sits**, not of its contents - every manifest under `gitops/` is applied to every cluster. An `enabled: false` value would not help, because the file would still be discovered and applied.

Two alternatives were considered:

- **`directory.exclude` on the root app.** Rejected because it makes the default deployment depend on a glob matching correctly, and the failure mode is silent: a typo in the pattern deploys MLOps to every EKS-only cluster, which is the exact outcome being prevented.
- **A second deployment profile** (separate root app per flavour). Rejected as disproportionate - one optional add-on does not justify duplicating the bootstrap path, and the requirement explicitly asked to avoid extra profiles and conditional logic.

Keeping it outside `gitops/` means an EKS-only deployment cannot receive MLOps resources by construction rather than by configuration. GitOps CI asserts this directly: it fails if any manifest under `gitops/` references the `mlops-platform` repository.

The `mlops` AppProject is the boundary once enabled. It permits the `mlops`, `mlops-system`, and `monitoring` namespaces - not `arc-runners`, since GitHub runners are a platform capability (decision #26) that MLOps workflows reach with `runs-on: platform-runners`. `Namespace` *is* granted, because the MLOps namespaces must not exist on an EKS-only cluster and so cannot come from the platform's shared namespace list.

Webhook configuration kinds were initially withheld, on the reasoning that a webhook registered from this project could intercept admission cluster-wide. They are now granted, because cert-manager and KServe both run from the MLOps repository and KServe registers six webhook configurations it cannot start without.

The original reasoning was also weaker than it looked. ArgoCD's `clusterResourceWhitelist` matches on group and kind only - it cannot scope by name - but `ClusterRoleBinding` was granted from the start, and a `ClusterRoleBinding` can bind cluster-admin to a ServiceAccount in `mlops-system`, which is a more direct escalation than a webhook. Any project permitted to install Kubernetes operators is trusted at roughly that level regardless. The controls doing real work are the namespace destinations and `sourceRepos`, not the cluster-resource list.

This is worth being explicit about rather than implying the project is a sandbox: it is a trust boundary for *accidents and scope creep*, not a containment boundary against a hostile manifest.

**Trade-off:** the two files in `optional/mlops/` are applied by hand and are therefore not self-healing - editing them in Git does not change the cluster until they are re-applied. That is inherent to being opt-in: a self-healing toggle would have to be declared somewhere the root app reads, which is the thing being avoided.

SimpleTimeService is unaffected in both directions. It is deployed by `gitops/app/simple-time-service/` as the platform's own demonstration, is not referenced by the MLOps Application, and is neither deployed nor removed when MLOps is enabled.

---

## 28. Workload IAM - Tag-Scoped IRSA, Split Read/Write from Read-Only

**Chosen:** Terraform creates two IRSA roles - `mlops-pipeline` (read/write) and `mlops-serving` (read-only) - authorised by resource *tag* rather than by ARN. Crossplane does not manage IAM.

Crossplane provisioning a bucket and a workload *using* that bucket are separate concerns with separate identities. The Crossplane provider roles are a control plane — create, configure, delete — and deliberately hold no data-plane permissions. Nothing was giving application pods access to the resources being provisioned for them.

**The policy names no resources, and does not need to.** Terraform cannot reference a bucket Crossplane has not created yet, and a Terraform change per bucket would defeat self-service provisioning. Every S3, SQS, and ECR data-plane action supports tag conditions, and for S3 the `s3:BucketTag` key applies to object-level actions as well as bucket-level ones — which is what makes a tag-scoped *object* policy possible at all. So the grant is a tag match: tagging a Crossplane-provisioned bucket `Workload=mlops` is what gives the role access to it, with no IAM change and no Terraform run.

That makes a tag load-bearing for authorisation, which is worth stating plainly: whoever can set tags on a Crossplane resource can bring it into the role's scope. Nothing enforces the tag, so a bucket created without it is simply unreadable — `AccessDenied`, which is the safe direction to fail.

**Two roles, split on a namespace boundary that already exists.** This began as one shared role and was split. The workloads do not need the same thing, and one is materially more exposed: the KServe predictor runs model code and serves external inference requests, and all it needs is to download a model artifact. Under a shared role it also held `s3:DeleteObject` on the dataset bucket, so a compromised predictor could have deleted every dataset. `mlops` is the serving namespace while `mlops-system` and `kubeflow` are platform and pipelines, so the identity boundary needed no new convention - it is the namespace boundary.

Deliberately not split further. A role per component would need per-ServiceAccount trust policies, which reintroduces exactly what IRSA was chosen to avoid: Kubeflow Pipelines alone creates **16** ServiceAccounts whose names change between releases, each needing a Terraform change in a different repository. Read/write versus read-only is where the risk actually sits.

**IRSA rather than Pod Identity**, deliberately opposite to the Crossplane providers (decision #24). A Pod Identity association is an exact namespace/ServiceAccount pair and cannot wildcard. These trust policies use `StringLike` on a namespace, so the consuming repository names its own service accounts without a platform change. The trust policy is only permission to assume - the actual grant is the `eks.amazonaws.com/role-arn` annotation on a ServiceAccount, which keeps the opt-in in the consuming repo.

`kubeflow` is in that list because Kubeflow Pipelines stores run artifacts in S3 and its object store layer supports `credentials.fromEnv`, resolving through the AWS SDK default chain - so the KFP API server, workflow controller, and every pipeline step pod authenticate through this role instead of static access keys in a Secret. KFP occupies its own namespace rather than `mlops-system` because its upstream Kustomize overlay hardcodes `namespace: kubeflow` and warns that moving it also requires patching a cluster-scoped ClusterRoleBinding, whose subject namespace the kustomize namespace transformer does not rewrite. The trade-off is namespace-level granularity — any pod in `mlops` or `mlops-system` can assume the role, which suits a single-team namespace and would need exact service account names if those namespaces ever host more than one team.

This also means writing the role longhand rather than through `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts`, which emits `StringEquals` on `sub` and cannot express the wildcard.

**Why not let Crossplane manage IAM.** Adding `provider-aws-iam` would keep the bucket and its role together in the consuming repository — genuinely more self-service. It is rejected *for this environment*: a provider that can create roles and attach policies is a direct privilege-escalation path to account admin. See decision #29 for what changes that calculus.

The runner role (`terraform/arc-runner-irsa.tf`) follows the same pattern with exact-ServiceAccount trust rather than a wildcard, because `arc-runners` is shared infrastructure where a new identity should require a deliberate change.

---

## 29. IAM Guardrails Assumed at the Account Layer, Not the Org Layer

**Recorded because it is an assumption, not a conclusion.** Every IAM decision in this document reasons about blast radius *within* a single AWS account. None of them assume an AWS Organization, a Service Control Policy, or a permissions boundary — because this platform does not have one.

That assumption is what makes several decisions come out the way they do, and it is worth making explicit rather than leaving implicit:

- **Decision #24** keeps Crossplane out of IAM entirely, and states "none of the three roles can reach IAM, EC2, or anything else" as an architectural property. It is really a consequence of having no org-level guardrail to catch an escalation.
- **Decision #28** puts workload roles in Terraform rather than letting Crossplane provision them, for the same reason.

**What changes with guardrails in place.** A permissions boundary caps what any role can do — effective permissions become the intersection of the attached policy and the boundary — so a provider that attaches `AdministratorAccess` to a role it created still produces a role that cannot exceed the ceiling. An SCP makes that ceiling non-bypassable, which is the part that actually matters: a boundary condition written only into Crossplane's own IAM policy is weak, because anyone with account admin can edit that policy. The usual SCP shape is:

- Deny `iam:CreateRole` / `AttachRolePolicy` / `PutRolePolicy` unless `iam:PermissionsBoundary` equals a specific policy ARN
- Deny `iam:DeleteRolePermissionsBoundary` and `iam:PutRolePermissionsBoundary` outside a break-glass principal
- Deny `iam:CreatePolicyVersion` on the boundary policy itself, or the ceiling can be raised
- Deny `iam:*` against platform roles — node roles, the Crossplane provider roles, break-glass

Plus path scoping, so `iam:CreateRole` is limited to `arn:aws:iam::<acct>:role/crossplane/*` and cannot reach `/platform/`.

The one commonly missed: **`iam:PassRole`**. Creating a role is not the only escalation path — passing an existing privileged role to a service that acts as it is just as effective, and a permissions boundary on a newly created role does nothing about it. `iam:PassRole` needs its own scoping, by path and with an `iam:PassedToService` condition.

**With that in place, `provider-aws-iam` becomes the right answer** and workload roles move into Crossplane alongside the resources they grant access to. The tag-scoped Terraform role in decision #28 becomes the fallback rather than the design.

It is not purely a security question either. The tag-scoped role needs no change per bucket, so self-service buys little here. Crossplane-managed IAM earns its keep when each workload needs a *bespoke* policy — at which point a Terraform round-trip per workload is the bottleneck, and with a boundary and SCP it is safe to hand over.

This platform runs in a single account with `enable_cluster_creator_admin_permissions = true` and a public EKS endpoint, both already recorded as demo trade-offs. Adding org-level guardrails is out of scope for it, but the absence should be a stated assumption rather than an invisible one.

---

## 30. KEDA for Event-Driven Work, Not a Polling Deployment

**Decision:** install KEDA as a platform capability, and have consumers declare
`ScaledJob`s rather than run long-lived pollers.

**Context.** The first design for the MLOps dataset ingestion worker was a
Deployment with a `while True` loop doing SQS long-polling. It works, and at
20-second long polls it costs about 130k API calls a month — effectively free.

The problem is not the API calls, it is the pod. Datasets arrive days or weeks
apart, so that pod spends essentially all of its life idle, and an idle pod
cannot be consolidated away by Karpenter. The cost of waiting is a node, not a
request.

**Alternatives considered.**

A **CronJob** calling the worker in drain mode needs no new controller and
costs nothing while idle. It was the leading option until the latency was
priced: with a 15-minute schedule, a dataset uploaded during a demo waits up to
15 minutes for anything to happen. KEDA's `pollingInterval: 30` makes that ~30
seconds.

**Keeping the Deployment** was rejected on the idle-node argument above.

**Consequences.**

- One more controller to run and upgrade. KEDA is a general capability rather
  than an MLOps one, so it sits in `gitops/auto-scaling/` beside Karpenter and
  the EKS-only cluster gets it too — it just has nothing to scale.
- The operator needs to read the external metric, so `terraform/keda.tf`
  creates a role with `sqs:GetQueueAttributes` on **two named queue ARNs** and
  nothing else, bound by EKS Pod Identity. A wildcard here would let anything
  in the `keda` namespace enumerate the depth of every queue in the account.
- `scaleOnInFlight` must be set to `"false"` by consumers running `ScaledJob`s.
  It defaults to true, which counts in-flight messages — so KEDA would see
  depth ≥ 1 for a whole in-progress run and start a second Job on top of the
  first. The default is right for a Deployment and wrong for a Job.
- The application code did not change. `--drain` serves a CronJob and a
  ScaledJob equally; only the manifest differs.

---

## 31. Cleanup Deletes Crossplane Resources Before the Cluster

**Decision:** `cleanup.sh` deletes Crossplane-managed AWS resources first, as
its very first action, and waits for Crossplane to confirm.

**Context.** Crossplane-managed resources are **not in Terraform state**.
Terraform created the cluster; Crossplane running inside that cluster created
the buckets, repositories, queues and rules that consuming projects declared.
So `terraform destroy` does not touch them, and destroying the cluster first
removes the only thing that knows they exist.

The consequence is not untidiness. **S3 bucket names are globally unique**, so
an orphaned bucket makes the *next* bootstrap of this platform fail to create
it — and the orphan bills in the meantime.

**Implementation notes.**

- It runs before `cleanup_kubernetes_resources`, which scales ArgoCD and the
  controllers to zero. Crossplane has to be alive and reconciling to delete
  anything, and ArgoCD has to be alive to stop re-creating it.
- Nothing hardcodes a consuming project's resource names. Crossplane gives
  every managed-resource CRD the `managed` category, so the set is discovered
  with `kubectl get managed -A`. This repository stays free of knowledge about
  what any particular consumer declared.
- Buckets are emptied first, including **noncurrent versions and delete
  markers**. Versioning is on, so `aws s3 rm --recursive` leaves every old
  version behind and the `Bucket` resource then sits in `Deleting` forever with
  `BucketNotEmpty`.
- On timeout it strips finalizers so the teardown is not blocked, and says
  loudly that this **orphans** whatever is left — removing a finalizer tells
  Kubernetes the resource is gone, not AWS.
- `verify_cleanup` then looks for anything still tagged
  `ManagedBy=crossplane` via the Resource Groups Tagging API, and checks that
  both GitHub App secrets were actually deleted rather than left *scheduled*
  for deletion, which would reserve the name.

---

## 32. Payload Logging Costs the Predictor Its Read-Only Property

**Decision:** grant the MLOps serving role `s3:PutObject`, scoped to the
`observations/` prefix.

**Context.** The serving role was strictly read-only, and the policy said so in
a comment: *"No PutObject, no DeleteObject, no multipart actions. A compromised
predictor pod cannot modify or destroy anything in these buckets."*

KServe v0.21's inference logger writes batched parquet payload logs directly to
blob storage, and it runs **inside the predictor pod** — so it carries that
role. Without the grant it fails every upload and drift detection has nothing
to compare live traffic against.

**Alternatives considered.**

A **receiver service** in the cluster, holding the pipeline role, with the
logger POSTing CloudEvents to it. That keeps the predictor read-only, at the
cost of a component in the prediction path that has to be run, scaled and
paged for — to do something the logger already does.

**Consequences.** The concession is deliberately minimal: one action, scoped by
resource pattern to `arn:aws:s3:::*/observations/*`, still gated on the bucket's
`Workload` tag. No delete, no ACL, no multipart abort. The buckets are
versioned, so even an overwrite inside the prefix retains the prior version.

What is **not** preserved is the absolute claim. A compromised predictor can
now append objects under its own log prefix. That is the price of having
production data to detect drift with, and the file-level `checkov` suppression
was updated to stop asserting the policy grants no write action — a stale
justification in code is worse than none.

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
