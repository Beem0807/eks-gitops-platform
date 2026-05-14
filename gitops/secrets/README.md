# Secrets Management - External Secrets Operator and Reloader

The `gitops/secrets/` directory deploys three ArgoCD apps that together handle secret synchronisation from AWS Secrets Manager into the cluster and automatic pod rollouts when secrets change.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `external-secrets/external-secret-operator.yaml` | External Secrets Operator v0.10.7 - controller, webhook, cert-controller | 1 | `external-secrets` |
| `external-secrets/cluster-secret-store.yaml` | `ClusterSecretStore` named `aws-secrets-manager` - cluster-wide AWS Secrets Manager backend | 4 | `external-secrets` |
| `reloader/reloader.yaml` | Stakater Reloader v1.1.0 - rolls Deployments when referenced Secrets or ConfigMaps change | 1 | `reloader` |

Wave ordering ensures the ESO operator and its admission webhook are fully ready before the `ClusterSecretStore` (wave 4) is applied, and the `ClusterSecretStore` is ready before any `ExternalSecret` (wave 5) tries to use it.

---

## Architecture

```
AWS Secrets Manager
  ├── argocd-admin              (adminPasswordHash, adminPasswordMtime)
  ├── grafana-admin             (adminUser, adminPassword)
  └── alertmanager-webhook      (slackWebhookUrl)
          │
          │  ExternalSecret (1h refresh)
          ▼
External Secrets Operator
  │  reads via IRSA (GetSecretValue on tagged secrets)
  │  writes Kubernetes Secrets
  ▼
Kubernetes Secrets
  ├── argocd/argocd-secret              (admin.password, admin.passwordMtime)
  ├── monitoring/grafana-admin          (admin-user, admin-password)
  └── monitoring/alertmanager-webhook   (slack-webhook-url)
          │
          │  Reloader watches for changes
          ▼
Deployments roll automatically
```

---

## External Secrets Operator

Installs the controller, admission webhook, and cert-controller - all pinned to core nodes.

| Setting | Value |
|---------|-------|
| Chart | `external-secrets` v0.10.7 (from `https://charts.external-secrets.io`) |
| CRD install | `installCRDs: true` |
| IRSA | `<cluster-name>-external-secrets-irsa` |

The IRSA policy (in `terraform/external-secrets-irsa.tf`) allows `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` only on secrets tagged `ExternalSecret=true`. All three secrets provisioned by Terraform carry this tag.

Verify the operator is running:

```bash
kubectl get pods -n external-secrets
kubectl get crds | grep external-secrets
```

---

## ClusterSecretStore

A single `ClusterSecretStore` named `aws-secrets-manager` is shared across all namespaces. It points at AWS Secrets Manager in the cluster's region, using the ESO service account (and its IRSA role) for authentication.

```yaml
provider:
  aws:
    service: SecretsManager
    region: <from ArgoCD cluster secret label>
    auth:
      jwt:
        serviceAccountRef:
          name: external-secrets
          namespace: external-secrets
```

The region is injected at deploy time from the ArgoCD cluster secret `region` label - no hardcoded values in the manifest.

Verify it is ready:

```bash
kubectl get clustersecretstore aws-secrets-manager
# STATUS should be: Valid
```

---

## ExternalSecrets

Three `ExternalSecret` resources are deployed by their respective component apps (not from this directory). They all reference the `aws-secrets-manager` `ClusterSecretStore` and refresh every hour.

| ExternalSecret | Namespace | Secrets Manager secret | Keys synced | Target K8s secret | Creation policy |
|----------------|-----------|----------------------|-------------|-------------------|-----------------|
| `argocd-admin-password` | `argocd` | `argocd-admin` | `adminPasswordHash` → `admin.password`<br>`adminPasswordMtime` → `admin.passwordMtime` | `argocd-secret` | `Merge` - patches the existing ArgoCD secret |
| `grafana-admin` | `monitoring` | `grafana-admin` | `adminUser` → `admin-user`<br>`adminPassword` → `admin-password` | `grafana-admin` | `Owner` |
| `alertmanager-webhook` | `monitoring` | `alertmanager-webhook` | `slackWebhookUrl` → `slack-webhook-url` | `alertmanager-webhook` | `Owner` |

The ArgoCD secret uses `Merge` + `Retain` (deletion policy) because `argocd-secret` is pre-created by the ArgoCD Helm chart - ESO patches it rather than owning it.

Check the sync status of all ExternalSecrets:

```bash
kubectl get externalsecret -A
```

Force an immediate re-sync (e.g. after rotating a secret in Secrets Manager):

```bash
REFRESH_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

kubectl annotate externalsecret argocd-admin-password \
  -n argocd force-sync="${REFRESH_TS}" --overwrite

kubectl annotate externalsecret grafana-admin \
  -n monitoring force-sync="${REFRESH_TS}" --overwrite

kubectl annotate externalsecret alertmanager-webhook \
  -n monitoring force-sync="${REFRESH_TS}" --overwrite
```

> `upgrade.sh` does this automatically after every `terraform apply`.

---

## Rotating a secret

To rotate any secret without re-running the full bootstrap:

```bash
# 1. Update the value in AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id grafana-admin \
  --secret-string '{"adminUser":"admin","adminPassword":"<new-password>"}'

# 2. Force ESO to re-sync immediately
kubectl annotate externalsecret grafana-admin \
  -n monitoring force-sync="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --overwrite

# 3. Reloader detects the Secret change and rolls the Grafana Deployment automatically
kubectl rollout status deploy/prometheus-grafana -n monitoring
```

---

## Reloader

Stakater Reloader watches for changes to Secrets and ConfigMaps and triggers a rolling restart of any Deployment, StatefulSet, or DaemonSet annotated to watch them.

| Setting | Value |
|---------|-------|
| Chart | `reloader` v1.1.0 (from `https://stakater.github.io/stakater-charts`) |
| `watchGlobally` | `true` - watches all namespaces |

### Annotations

Opt a workload into Reloader watching by adding one of these annotations:

```yaml
# Roll when any referenced Secret or ConfigMap changes
annotations:
  reloader.stakater.com/auto: "true"

# Roll only when specific resources change
annotations:
  reloader.stakater.com/reload: "grafana-admin,grafana-config"
```

Prometheus and Alertmanager carry the `auto: "true"` annotation so they roll automatically when their credentials (Grafana admin secret, Alertmanager webhook secret) are rotated.

Verify Reloader is running:

```bash
kubectl get pods -n reloader
```

Check Reloader logs to confirm it detected a secret change:

```bash
kubectl logs -n reloader -l app=reloader --tail=50
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ClusterSecretStore` status `Invalid` | Check IRSA trust: `kubectl describe clustersecretstore aws-secrets-manager`. Confirm the ESO service account has the correct `eks.amazonaws.com/role-arn` annotation: `kubectl get sa external-secrets -n external-secrets -o yaml`. |
| ExternalSecret stuck in `SecretSyncedError` | Run `kubectl describe externalsecret <name> -n <namespace>` for the exact error. Common causes: Secrets Manager secret does not exist, missing `ExternalSecret=true` tag, or wrong property key name. |
| ExternalSecret `Ready` but pod not updated | Reloader is responsible for the rollout. Confirm the Deployment has the `reloader.stakater.com/auto: "true"` annotation and Reloader is running. |
| Secret not refreshing after Secrets Manager update | The refresh interval is 1h. Force an immediate sync with the `force-sync` annotation (see above), or use `upgrade.sh`. |
| `argocd-secret` patch fails | The `Merge` creation policy requires the target secret to already exist. Ensure ArgoCD has fully initialised before the `argocd-admin-password` ExternalSecret syncs (sync-wave 5 ensures this). |
