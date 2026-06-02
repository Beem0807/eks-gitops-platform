# Alertmanager Not Firing Alerts

## Symptoms

- A known condition exists (pod down, HPA at max) but no Slack message was received
- `kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093` → UI shows the alert as `firing` but it was never delivered
- Alertmanager logs show routing or webhook errors
- The `alertmanager-webhook` secret is missing or contains a stale URL

## Impact

- **Critical**: On-call is blind - incidents will not be paged until the routing is restored
- Prometheus rules are still evaluating; alerts fire in Prometheus but are silently dropped before reaching Slack

## Quick Checks

```bash
# Is Alertmanager running?
kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=alertmanager

# Alertmanager logs
kubectl logs -n monitoring \
  alertmanager-kube-prometheus-alertmanager-0 --tail=100

# Check the Alertmanager UI for active alerts and routing
kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093
# Open http://localhost:9093
# Status → Config - confirm the routing config is loaded
# Alerts - confirm the alert shows as "firing"

# Is the webhook secret present and non-empty?
kubectl get secret alertmanager-webhook -n monitoring
kubectl get secret alertmanager-webhook -n monitoring \
  -o jsonpath='{.data.slackWebhookUrl}' | base64 -d

# Is the ExternalSecret that syncs the webhook secret healthy?
kubectl get externalsecret -n monitoring
kubectl describe externalsecret alertmanager-webhook -n monitoring
```

## Root Causes

| Cause | How to Identify |
|---|---|
| Alert missing `notify: slack` label | Alert fires in Prometheus UI but Alertmanager routing tree skips it |
| Webhook secret missing / empty | Alertmanager logs: `http: error on request` or `invalid URL` |
| ExternalSecret for webhook URL not syncing | `kubectl get externalsecret -n monitoring` shows `SecretSyncedError` |
| Alertmanager pod not running | `kubectl get pods -n monitoring` shows 0/1 |
| AlertmanagerConfig not loaded | Alertmanager UI → Status → Config shows no receiver for `slack` |
| Slack webhook URL expired or revoked | Alertmanager logs: `HTTP 403` or `token_revoked` from Slack API |
| Alert is silenced | Alertmanager UI → Silences - check for active silences |
| Alert is in `pending` state, threshold not yet met | Alertmanager UI shows `pending` - wait for the `for:` duration to elapse |

## Fix

### Alert missing `notify: slack` label
> **This platform**: The `AlertmanagerConfig` in `gitops/alerts/alertmanager-slack.yaml` routes alerts **only if they carry the label `notify: slack`**. If a PrometheusRule does not include this label, the alert will fire in Prometheus but be dropped by the default Alertmanager route.

```yaml
# In your PrometheusRule alert definition, add:
labels:
  notify: slack
  severity: critical   # or warning
```

Check `gitops/alerts/simple-time-service-alerts.yaml` as a reference - both alerts there include `notify: slack`.

### Webhook secret missing or stale
```bash
# Check the secret
kubectl get secret alertmanager-webhook -n monitoring \
  -o jsonpath='{.data.slackWebhookUrl}' | base64 -d

# If empty or wrong, the ExternalSecret sync is broken
kubectl describe externalsecret alertmanager-webhook -n monitoring
```

If the ExternalSecret is failing, follow the `external-secrets-not-syncing.md` runbook. The secret syncs from AWS Secrets Manager key `alertmanager-webhook`, property `slackWebhookUrl`.

> **This platform**: The webhook URL must be stored in Secrets Manager under a key tagged `ExternalSecret: "true"`. If the tag is missing, the IRSA policy will deny access.

### Alertmanager not reloading after secret rotation
Alertmanager must be restarted to pick up a rotated webhook secret. Reloader is configured on the Alertmanager deployment.

```bash
# Check if Reloader is running
kubectl get pods -n reloader -l app.kubernetes.io/name=reloader

# If Reloader missed the rotation, force-restart Alertmanager manually
kubectl rollout restart statefulset \
  alertmanager-kube-prometheus-alertmanager -n monitoring
```

### AlertmanagerConfig not loaded
```bash
# Check if the AlertmanagerConfig object exists
kubectl get alertmanagerconfig -n monitoring

# Check Alertmanager loaded it - compare with what's in the UI
kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093
# http://localhost:9093/#/status - look for the slack receiver in the config output
```

> **This platform**: `alertmanagerConfigMatcherStrategy.type: None` is set. This means AlertmanagerConfigs apply globally without requiring a namespace matcher - no namespace label is needed for the config to be picked up.

### Slack webhook expired
```bash
# Alertmanager logs will show the Slack error code
kubectl logs -n monitoring alertmanager-kube-prometheus-alertmanager-0 \
  | grep -i "slack\|webhook\|403\|revoked"

# Rotate the webhook URL in AWS Secrets Manager, then trigger a re-sync:
kubectl annotate externalsecret alertmanager-webhook -n monitoring \
  force-sync=$(date +%s) --overwrite

# Then restart Alertmanager to pick up the new secret
kubectl rollout restart statefulset \
  alertmanager-kube-prometheus-alertmanager -n monitoring
```

### Send a test alert to verify routing end-to-end
```bash
kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093

curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "notify": "slack",
      "severity": "warning"
    },
    "annotations": {
      "summary": "Manual test alert"
    }
  }]'
# Check Slack for the message
```

## Prevention

- All PrometheusRules that need Slack delivery must include `notify: slack` in labels - document this in onboarding guides and Kyverno policies if/when you add a rule enforcement policy
- Alert on `alertmanager_notifications_failed_total > 0` - fires when the webhook itself is erroring
- Rotate the Slack webhook URL via Secrets Manager (not `kubectl edit`) so Reloader picks it up automatically
- Run the test alert curl command as part of quarterly on-call readiness checks
