# Security

The `gitops/security/` directory deploys the Kyverno admission controller, ClusterPolicy rules, and the Policy Reporter UI into the `security` namespace.

| File | What it deploys | Sync wave |
|------|----------------|-----------|
| `kyverno/kyverno.yaml` | Kyverno admission controller v3.2.7 | 3 |
| `kyverno/kyverno-policies.yaml` | Four `ClusterPolicy` rules (Audit mode) | 5 |
| `kyverno/policy-reporter.yaml` | Policy Reporter UI v2.24.1 + Kyverno plugin | 6 |

---

## Architecture

```
Every pod admission request
        │
        ▼
Kyverno Admission Controller
  │  evaluates ClusterPolicy rules
  │  writes results to PolicyReport / ClusterPolicyReport objects
  ▼
Policy Reporter UI
  │  reads PolicyReport / ClusterPolicyReport objects via Kubernetes API
  │  displays violations, pass/fail summaries per namespace
  ▼
kubectl port-forward svc/policy-reporter-ui -n security 8080:8080
```

---

## Kyverno

Installs the admission controller, background controller, cleanup controller, and reports controller. All four controllers are pinned to `app=core` nodes.

| Setting | Value |
|---------|-------|
| Chart | `kyverno` v3.2.7 from `https://kyverno.github.io/kyverno` |
| Admission controller replicas | 1 |
| Namespace | `security` |
| Node affinity | `app=core` (via `global.nodeSelector`) |
| Images | `public.ecr.aws` registry (VPC-accessible) |

### Components

| Controller | Purpose |
|-----------|---------|
| `admissionController` | Validates/mutates resources on admission - the core webhook |
| `backgroundController` | Re-evaluates existing resources against policies (background scan) |
| `cleanupController` | Runs `ClusterCleanupPolicy` rules on a schedule |
| `reportsController` | Aggregates admission results into `PolicyReport` and `ClusterPolicyReport` objects |

Verify all pods are running:

```bash
kubectl get pods -n security -l app.kubernetes.io/name=kyverno
```

---

## ClusterPolicies

Four policies are deployed, all set to **Audit** mode (`validationFailureAction: Audit`). Audit mode writes results to `PolicyReport` objects without blocking pod admission - safe to enable on existing clusters.

| Policy | Category | Severity | What it checks |
|--------|----------|----------|----------------|
| `require-resource-limits` | Best Practices | Medium | Every container must declare `cpu` and `memory` limits |
| `disallow-privileged-containers` | Pod Security | High | `securityContext.privileged` must not be `true`; excludes `kube-system` and `karpenter` namespaces |
| `disallow-latest-tag` | Best Practices | Medium | Images must have an explicit tag; `:latest` is not allowed |
| `require-run-as-non-root` | Pod Security | Medium | `runAsNonRoot: true` must be set at pod or container level |

### Checking policy results

```bash
# List all ClusterPolicies
kubectl get clusterpolicy

# View policy reports per namespace
kubectl get policyreport -A

# Inspect violations in a specific namespace
kubectl describe policyreport -n <namespace>

# Check background scan results
kubectl get clusterpolicyreport
```

### ignoreDifferences

Kyverno's admission webhook mutates every `ClusterPolicy` it processes by injecting `skipBackgroundRequests: true` at the rule level. This field is not in the CRD schema for Server-Side Apply, so ArgoCD would permanently show the app as `OutOfSync`. The `ignoreDifferences` block on the ApplicationSet suppresses this:

```yaml
ignoreDifferences:
  - group: kyverno.io
    kind: ClusterPolicy
    jqPathExpressions:
      - .spec.rules[].skipBackgroundRequests
```

---

## Policy Reporter

Provides a read-only web UI over the `PolicyReport` and `ClusterPolicyReport` objects written by Kyverno.

| Setting | Value |
|---------|-------|
| Chart | `policy-reporter` v2.24.1 from `https://kyverno.github.io/policy-reporter` |
| Kyverno plugin | enabled - enriches reports with policy metadata |
| Access | `kubectl port-forward` only (no ingress) |
| Namespace | `security` |

### Accessing the UI

```bash
kubectl port-forward svc/policy-reporter-ui -n security 8080:8080
```

Then open `http://localhost:8080`.

### Verify pods are running

```bash
kubectl get pods -n security
```

Expected pods:

| Pod | Purpose |
|-----|---------|
| `policy-reporter-*` | Core reporter - watches PolicyReport objects |
| `policy-reporter-kyverno-plugin-*` | Kyverno plugin - enriches reports with policy details |
| `policy-reporter-ui-*` | Web UI |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Kyverno pods pending | Check taint toleration: `kubectl describe pod -n security <pod>`. All components require `app=core:NoSchedule` toleration. |
| ClusterPolicy shows `OutOfSync` in ArgoCD | Kyverno webhooks inject `skipBackgroundRequests` into rule specs. The `ignoreDifferences` block handles this - if still drifting, run `argocd app diff kyverno-policies-in-cluster`. |
| Policy Reporter UI blank / no data | Policies generate reports only after pod admission activity. Restart any pod to trigger report generation: `kubectl rollout restart deploy/<name> -n <namespace>`. |
| `policy-reporter-kyverno-plugin` pending | Check node scheduling: `kubectl describe pod -n security -l app.kubernetes.io/name=policy-reporter-kyverno-plugin`. Toleration for `app=core` must be present. |

For operational incidents see the runbooks:

| Symptom | Runbook |
|---------|---------|
| `kubectl get clusterpolicy` returns nothing / Kyverno pods crash-looping / deployment blocked by admission webhook | [kyverno-policy-violation.md](../../docs/runbooks/kyverno-policy-violation.md) |
