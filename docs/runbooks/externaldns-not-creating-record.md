# ExternalDNS Not Creating DNS Record

## Symptoms

- Newly deployed service/ingress is not reachable by its hostname
- `nslookup <hostname>` or `dig <hostname>` returns `NXDOMAIN`
- Route 53 hosted zone does not contain the expected `A` or `CNAME` record
- ExternalDNS logs show no upsert events or show errors
- No change in Route 53 several minutes after ArgoCD sync completes

## Impact

- **High**: Service is deployed but completely unreachable via its DNS name
- HTTPS traffic cannot reach the ALB; TLS cert validation fails on first request

## Quick Checks

```bash
# ExternalDNS pod status
kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns

# Controller logs - look for "upsert" events or errors
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=200

# Check the Ingress has an ADDRESS (ALB must be provisioned first)
kubectl get ingress -n <namespace> -o wide

# What sources and domain filters is ExternalDNS watching?
kubectl get deployment -n external-dns external-dns \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'

# Verify the hosted zone exists and contains the expected record
aws route53 list-hosted-zones \
  --query 'HostedZones[].{Name:Name,Id:Id}'

aws route53 list-resource-record-sets \
  --hosted-zone-id <zone-id> \
  --query "ResourceRecordSets[?Name=='<hostname>.']"

# IRSA - confirm the correct role is annotated
kubectl get sa external-dns -n external-dns \
  -o jsonpath='{.metadata.annotations}'
```

## Root Causes

| Cause | How to Identify |
|---|---|
| ExternalDNS pod not running | `kubectl get pods -n external-dns` shows 0/1 |
| IRSA role missing `route53:ChangeResourceRecordSets` | `AccessDenied` in ExternalDNS logs |
| `domainFilters` doesn't match the Ingress hostname | Logs show `Skipping record ...` |
| Ingress has no `ADDRESS` yet (ALB not provisioned) | `kubectl get ingress` shows empty ADDRESS column |
| `txt-owner-id` conflict - two ExternalDNS instances managing same zone | Ownership TXT record owned by different ID; no upsert |
| `--aws-zone-type=public` but zone is private | Logs show `no zones found` |

## Fix

### ExternalDNS pod crash-looping
```bash
kubectl describe pod -n external-dns \
  -l app.kubernetes.io/name=external-dns
kubectl logs -n external-dns \
  -l app.kubernetes.io/name=external-dns --previous
kubectl rollout restart deployment external-dns -n external-dns
```

### IRSA permissions
```bash
# Check the annotated role
kubectl get sa external-dns -n external-dns \
  -o jsonpath='{.metadata.annotations}'
```

The IAM policy (in `terraform/external-dns-irsa.tf`) grants:
- `route53:ChangeResourceRecordSets`
- `route53:ListHostedZones`
- `route53:ListResourceRecordSets`
- `route53:ListTagsForResource` / `route53:ListTagsForResources`

If the role is missing, re-apply:
```bash
cd terraform && terraform apply -target=module.external_dns_irsa
```

> **This platform**: IRSA role follows pattern `<cluster-name>-external-dns-irsa`. The service account is `external-dns` in namespace `external-dns`.

### Domain filter mismatch
The `domainFilters` value is injected from the ArgoCD cluster annotation `domain-name` at deploy time.

```bash
# Check what domain filter is actually in use
kubectl get deployment external-dns -n external-dns \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep domain
```

If wrong, update the cluster secret annotation in ArgoCD and resync the `external-dns` ApplicationSet.

### Ingress has no ALB address yet
```bash
# Wait for ALB provisioning first
watch kubectl get ingress -n <namespace>
# Once ADDRESS is populated, ExternalDNS picks it up within ~1 minute
# If ADDRESS never appears, follow the alb-503.md runbook
```

### txt-owner-id conflict
> **This platform**: `txtOwnerId` is set to the cluster name (e.g., `simple-eks`) via the ApplicationSet value. If a second ExternalDNS instance is running against the same zone with a different owner ID, records will not be updated.

```bash
# Check for duplicate TXT ownership records in Route 53
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> \
  --query "ResourceRecordSets[?Type=='TXT']"
```

### Force a re-evaluation
```bash
# Restart ExternalDNS to immediately re-scan all sources
kubectl rollout restart deployment external-dns -n external-dns
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -f
```

## Prevention

> **This platform**: ExternalDNS watches both `ingress` and `service` sources, and only public Route 53 zones (`--aws-zone-type=public`). Private hosted zones are not managed.

- Validate ExternalDNS is running and has correct IRSA in the post-deploy smoke test
- Run `dig +short <hostname>` as a step in CI smoke tests
- Alert on ExternalDNS pod restarts > 2 in 5 minutes
- If adding a second cluster, ensure each uses a unique `txtOwnerId` to avoid ownership conflicts in shared zones
