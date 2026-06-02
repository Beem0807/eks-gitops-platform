# External Secrets Not Syncing

## Symptoms

- Pods fail to start with `CreateContainerConfigError` or `Error` - missing env vars or mounted secrets
- `kubectl get externalsecret -n <namespace>` shows status `SecretSyncedError` or `NotReady`
- A secret exists in AWS Secrets Manager but not in the Kubernetes namespace
- ArgoCD shows the app healthy but the pod crashloops after deploy

## Impact

- **High**: Any workload that depends on a synced secret cannot start
- Secret rotation has no effect if the ExternalSecret sync is broken

## Quick Checks

```bash
# List all ExternalSecrets and their sync status
kubectl get externalsecret -A

# Describe a specific ExternalSecret for the error condition
kubectl describe externalsecret <name> -n <namespace>

# ESO controller logs
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets --tail=100

# ClusterSecretStore status - is the store itself healthy?
kubectl get clustersecretstore
kubectl describe clustersecretstore <name>

# Verify the target secret was created
kubectl get secret <secret-name> -n <namespace>

# IRSA - confirm the correct role is annotated
kubectl get sa external-secrets -n external-secrets \
  -o jsonpath='{.metadata.annotations}'
```

## Root Causes

| Cause | How to Identify |
|---|---|
| IRSA role missing `secretsmanager:GetSecretValue` | ESO logs: `AccessDenied`; ExternalSecret status: `SecretSyncedError` |
| Secret not tagged `ExternalSecret: "true"` in AWS | `AccessDenied` even though role exists - IAM policy uses tag condition |
| Wrong secret name or key in the ExternalSecret spec | ESO logs: `ResourceNotFoundException` |
| ClusterSecretStore not ready | `kubectl get clustersecretstore` shows `NotReady` |
| ESO controller not running | `kubectl get pods -n external-secrets` shows 0/1 |
| Secret deleted manually from Kubernetes | ExternalSecret shows `Ready` but secret is missing - ESO re-creates on next poll |

## Fix

### ESO controller not running
```bash
kubectl rollout restart deployment external-secrets -n external-secrets
kubectl rollout status deployment external-secrets -n external-secrets
```

### IRSA permissions / missing tag on secret
> **This platform**: The IRSA policy in `terraform/external-secrets-irsa.tf` grants `secretsmanager:GetSecretValue` **only on secrets tagged** `ExternalSecret: "true"`. If a secret is missing this tag, access will be denied even though the role is correct.

```bash
# Verify the secret has the required tag in AWS
aws secretsmanager describe-secret --secret-id <secret-name> --region <region> \
  --query 'Tags'

# If the tag is missing, add it
aws secretsmanager tag-resource \
  --secret-id <secret-name> \
  --tags Key=ExternalSecret,Value=true \
  --region <region>
```

### ClusterSecretStore not ready
```bash
kubectl describe clustersecretstore <name>
# Look at the conditions - common causes: IRSA role wrong, region wrong, connectivity

# Check what IRSA role the store is using
kubectl get clustersecretstore <name> \
  -o jsonpath='{.spec.provider.aws.auth.jwt.serviceAccountRef}'
```

### Wrong secret name or missing key
```bash
# Check the ExternalSecret spec
kubectl get externalsecret <name> -n <namespace> -o yaml | grep -A 10 "remoteRef"

# Verify the secret and key exist in Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id <secret-name> --region <region> \
  --query 'SecretString'
```

### Force a re-sync
```bash
# Annotate the ExternalSecret to trigger an immediate refresh
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

## Prevention

> **This platform**: The Slack webhook secret used by Alertmanager also syncs via ExternalSecret (`gitops/alerts/alertmanager-webhook-secret.yaml`). If that sync breaks, Alertmanager silently loses its Slack route - no alerts will fire. Treat ESO health as part of the alerting pipeline, not just application config.

- Monitor `externalsecret_sync_calls_error` metric from ESO
- Alert on any ExternalSecret in `SecretSyncedError` state for > 5 minutes
- Always tag new secrets in AWS Secrets Manager with `ExternalSecret: "true"` before creating the ExternalSecret manifest
- Keep the ClusterSecretStore under `gitops/secrets/external-secrets/` - never create ad-hoc stores outside GitOps
