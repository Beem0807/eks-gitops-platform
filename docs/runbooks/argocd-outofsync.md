# ArgoCD Application OutOfSync

## Symptoms

- ArgoCD UI shows application status as `OutOfSync` or `Degraded`
- `argocd app list` shows `OutOfSync` in the SYNC column
- Slack/Alertmanager fires `ArgoCDAppOutOfSync` alert
- New commits to the GitOps repo are not reflected in the cluster

## Impact

- **Low**: App is out of sync but healthy - desired state in Git diverged from cluster, no live impact yet
- **High**: App is `OutOfSync` and `Degraded` - a rollout is failing or resources are in error state

## Quick Checks

```bash
# List all apps and their sync/health status
argocd app list

# Get detailed sync diff for a specific app
argocd app diff <app-name>

# Describe the app to see conditions and events
argocd app get <app-name>

# Check ArgoCD application controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100

# Check repo-server (template rendering errors show here)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100

# Check ArgoCD server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

## Root Causes

| Cause | How to Identify |
|---|---|
| Drift - someone applied `kubectl apply` directly | `argocd app diff` shows live resource differs from Git |
| Helm values changed but chart not re-rendered | `argocd app diff` shows values-only delta |
| Git repo unreachable / bad credentials | Repo-server logs show auth errors; app shows `ComparisonError` |
| Sync wave deadlock | One resource stuck in `Progressing`; blocks downstream wave |
| Hook job failure | `argocd app get` shows a `PreSync`/`PostSync` hook in `Failed` state |
| CRD not installed before CR | `ComparisonError: no matches for kind` in repo-server logs |

## Fix

### Trigger a manual sync
```bash
# Trigger a manual sync
argocd app sync <app-name>

# If resources need to be pruned (deleted from cluster)
argocd app sync <app-name> --prune
```

### Drift caused by manual `kubectl apply`
```bash
# Review what changed
argocd app diff <app-name>

# Hard refresh to bypass cache, then sync
argocd app get <app-name> --hard-refresh
argocd app sync <app-name> --prune
```

### Git repo / credentials issue
```bash
# Re-check repo connectivity
argocd repo list
argocd repo get <repo-url>

# Rotate credentials via the ArgoCD secret, then force a refresh
argocd app get <app-name> --hard-refresh
```

### Stuck sync-wave / hook failure
```bash
# Identify the stuck resource
argocd app get <app-name> --show-operation

# Terminate the stuck operation and retry
argocd app terminate-op <app-name>
argocd app sync <app-name>
```

## Prevention

- All ApplicationSets in this project already have `selfHeal: true` and `prune: true` - verify these are not accidentally removed when editing manifests in `gitops/`
- Pin Helm chart `targetRevision` to a specific version; floating versions cause surprise diffs on every ArgoCD refresh
- Add `argocd.argoproj.io/sync-wave` annotations deliberately - leave gaps (0, 10, 20) so you can insert waves without renumbering
- Alert on `ComparisonError` separately from `OutOfSync` - repo connectivity failures need a different response
