# Kyverno Policy Violation

## Symptoms

- Policy Reporter or Grafana shows policy violations for a workload
- A workload is non-compliant with a platform security policy
- Someone changed a policy from `Audit` to `Enforce` and a deployment is now being rejected with an admission webhook error like: `resource blocked by policy <policy-name>`

## Impact

- **Audit mode** (current default): No deployments are blocked - violations are reported only. Operational impact is zero.
- **Enforce mode**: Pods/Deployments that violate the policy are rejected at admission. Workloads cannot be created or updated until the violation is resolved.

> **This platform**: All four ClusterPolicies in `gitops/security/kyverno/kyverno-policies.yaml` are currently in **`Audit` mode**. Kyverno will **not block** any deployments. Violations appear in Policy Reporter only. If a policy was recently changed to `Enforce`, that is the likely cause of a blocked deployment.

## Quick Checks

```bash
# List all Kyverno ClusterPolicies and their enforcement mode
kubectl get clusterpolicy -o wide

# List policy violations
kubectl get policyreport -A
kubectl get clusterpolicyreport

# Describe a specific report for detail
kubectl describe policyreport <name> -n <namespace>

# If a deployment was rejected, check the admission webhook error
kubectl describe deployment <name> -n <namespace> | grep -A 10 "Events:"

# Kyverno controller logs
kubectl logs -n security \
  -l app.kubernetes.io/component=admission-controller --tail=100
```

## Current Policies (Audit Mode)

| Policy | What it checks |
|---|---|
| `require-resource-limits` | All containers must have CPU and memory limits set |
| `disallow-privileged-containers` | No containers may run as privileged (excludes `kube-system`, `karpenter`) |
| `disallow-latest-tag` | Image tags must not be `latest` or mutable |
| `require-non-root-user` | Containers must run as a non-root user |

## Fix

### Workload violates a policy (audit mode - no action required operationally)
The violation is informational. To resolve it properly, update the workload to comply:

**Missing resource limits:**
```yaml
resources:
  limits:
    cpu: 500m
    memory: 256Mi
```

**Latest/mutable image tag:**
```yaml
image:
  tag: "1.2.3"   # use a specific immutable tag, not "latest"
```

**Privileged container:**
```yaml
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
```

**Running as root:**
```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
```

> **This platform**: `charts/simple-time-service/values.yaml` already sets all of the above correctly. New workloads should follow the same pattern.

### A policy was changed to Enforce and is blocking a deployment
```bash
# Identify which policy is blocking
kubectl describe deployment <name> -n <namespace> | grep "blocked by policy"

# Immediate relief - set it back to Audit while you fix the workload
kubectl patch clusterpolicy <policy-name> \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Audit"}]'

# Then fix the workload spec and update gitops/security/kyverno/kyverno-policies.yaml
# to use "Enforce" only after all violations are resolved
```

### Kyverno webhook timing out (causing all admissions to fail)
If Kyverno itself is unhealthy, its admission webhook may block all resource creation cluster-wide.
```bash
# Check Kyverno admission controller pods
kubectl get pods -n security -l app.kubernetes.io/component=admission-controller

# If crash-looping, restart
kubectl rollout restart deployment kyverno-admission-controller -n security

# Emergency: if Kyverno is completely broken and blocking cluster operations,
# temporarily remove the webhook (restore by resyncing kyverno ArgoCD app)
kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
```

## Prevention

- Keep policies in `Audit` mode until all existing workloads are compliant - only switch to `Enforce` after reviewing the Policy Reporter dashboard
- Before switching any policy to `Enforce`, run: `kubectl get policyreport -A -o json | jq '[.items[].results[]] | map(select(.policy=="<policy-name>"))' ` to confirm zero violations
- Kyverno runs in the `security` namespace on `core` nodes - ensure core nodes are always provisioned before any workloads are deployed (controlled by sync wave ordering in ArgoCD)
