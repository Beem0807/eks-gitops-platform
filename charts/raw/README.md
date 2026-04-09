# charts/raw

A minimal, reusable Helm chart that renders any list of Kubernetes resources passed in via `values.yaml`. It exists so that every resource in the platform - including plain ConfigMaps - can be deployed through the same ArgoCD ApplicationSet pattern without needing a separate raw manifest tracked outside of `gitops/`.

---

## How it works

`templates/resources.yaml` loops over `.Values.resources` and renders each entry as a top-level YAML document:

```yaml
{{- range .Values.resources }}
---
{{ toYaml . }}
{{- end }}
```

Anything that is valid Kubernetes YAML can go in the `resources:` list.

---

## Usage

Reference `charts/raw` as the Helm source in any ArgoCD ApplicationSet:

```yaml
source:
  repoURL: https://github.com/Beem0807/eks-gitops-platform.git
  targetRevision: main
  path: charts/raw
  helm:
    releaseName: my-release
    values: |
      resources:
        - apiVersion: v1
          kind: ConfigMap
          metadata:
            name: my-config
            namespace: some-namespace
          data:
            key: value
```

---

## Used by

| ApplicationSet | What it deploys |
|----------------|----------------|
| `gitops/monitoring/grafana/simple-time-service-dashboard.yaml` | Grafana dashboard ConfigMap (label: `grafana_dashboard: "1"`) |
| `gitops/alerts/simple-time-service-alerts.yaml` | PrometheusRule CRD |
| `gitops/alerts/alertmanager-slack.yaml` | AlertmanagerConfig CRD |
| `gitops/logs/loki/grafana-loki-datasource.yaml` | Loki datasource ConfigMap (label: `grafana_datasource: "1"`) |
