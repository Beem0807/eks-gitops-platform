# SimpleTimeService - App

A minimal Python microservice that returns the current UTC timestamp and the caller's IP address as JSON.

## Response format

```json
{
  "timestamp": "2026-04-07T12:00:00.000000+00:00",
  "ip": "203.0.113.42"
}
```

## Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Returns `timestamp` and caller `ip` |
| `/health` | GET | Liveness / readiness probe (`{"status": "ok"}`) |
| `/metrics` | GET | Prometheus metrics (available on `latest` tag only) |

## Technology

- **Runtime**: Python 3.12 (slim base image)
- **Framework**: FastAPI + Uvicorn
- **Container**: single-stage build based on `python:3.12-slim`, kept small by clearing pip cache.
- **ASGI server**: Uvicorn (production-grade async Python server)
- **Metrics**: `prometheus-fastapi-instrumentator` — `/metrics` endpoint scraped by Prometheus via ServiceMonitor
- **Tracing**: OpenTelemetry SDK with OTLP HTTP exporter — a `TracerProvider` is always configured so every request gets a real span; spans are exported to Grafana Tempo only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set
- **Logging**: JSON-structured logs written to stdout; `trace_id` and `span_id` are injected into every log line for every HTTP request

---

## Running locally

### Docker Compose (recommended)

```bash
docker compose up --build
```

The service is available at `http://localhost:8080`. Logs include `trace_id` and `span_id` on every request even without a collector.

### Docker only

```bash
docker build -t simple-time-service ./app
docker run --rm -p 8080:8080 simple-time-service
```

### Verify

```bash
curl http://localhost:8080/
```

Expected response:

```json
{
  "timestamp": "2026-04-07T12:00:00.000000+00:00",
  "ip": "127.0.0.1"
}
```

---

## Docker image

The image is published on Docker Hub under two distinct tags:

| Tag | Metrics | Tracing | Use when |
|-----|---------|---------|----------|
| `v1` | No | No | Pinned baseline — original service without instrumentation |
| `latest` | Yes (`/metrics`) | Yes | Tracks `main` — full instrumentation; deploy with the Helm chart |

> **`latest`** includes the Prometheus `/metrics` endpoint and OpenTelemetry tracing. Tracing is off by default and activates only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set in the pod's environment. Use this tag when deploying with the Helm chart and `serviceMonitor.enabled=true`.

```bash
# No metrics (baseline)
docker pull nabeemdev/simple-time-service:v1

# With /metrics endpoint
docker pull nabeemdev/simple-time-service:latest
```

### Building and pushing your own image

The image is built as a **multi-platform manifest** targeting both `linux/amd64` and `linux/arm64` using Docker Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <your-dockerhub-username>/simple-time-service:latest \
  --push ./app
```

`--push` builds and pushes both platform variants to the registry in a single step.

**Why multi-platform?**
- Runs natively on both x86 EKS nodes (`m6a.large`) and ARM-based Graviton nodes (`m7g`, `t4g`)
- Works out of the box on Apple Silicon (M-series) development machines
- Docker automatically pulls the correct variant for the host architecture

> Requires `docker buildx` (included in Docker Desktop). The CI workflow handles this automatically via QEMU.

Then update the `image:` field in `k8s/microservice.yaml` before applying:

```yaml
image: docker.io/<your-dockerhub-username>/simple-time-service:latest
```

---

## CI - GitHub Actions

The workflow at `.github/workflows/app-image.yaml` automatically builds, scans, and pushes the Docker image to Docker Hub.

### Triggers

| Event | Condition | Behaviour |
|-------|-----------|-----------|
| Push to `main` | Files under `app/**` or the workflow file changed | Build → scan → push |
| Pull request to `main` | Same path filter | Build → scan (no push); results posted as PR comment |
| `workflow_dispatch` | Manual trigger from the Actions UI | Build → scan → push |

### Steps

1. **Build** - builds a `linux/amd64` image locally (not pushed) for scanning.
2. **Scan** - Trivy scans for `CRITICAL` and `HIGH` vulnerabilities (ignoring unfixed ones). The job fails and the PR is blocked if any are found. Results are posted as a comment on the PR and uploaded to the GitHub Security tab (SARIF).
3. **Push** - on merge to `main` only, rebuilds as a multi-platform manifest (`linux/amd64` + `linux/arm64`) and pushes to Docker Hub.

### Tagging strategy

| Tag | When applied | Notes |
|-----|-------------|-------|
| Short commit SHA (e.g. `a1b2c3d`) | Every push to `main` | Immutable per-commit reference |
| `latest` | Push to `main` only | Tracks the current `main` - includes Prometheus `/metrics` endpoint |
| `v1` | Pinned manually | Baseline version without metrics |

### Required secrets

Before the workflow can push to Docker Hub, add these two secrets to the repository (**Settings → Secrets and variables → Actions → New repository secret**):

| Secret | Value |
|--------|-------|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | A Docker Hub access token (not your password) |

Generate a token at **Docker Hub → Account Settings → Personal access tokens**.

### Branch protection

To enforce that the scan must pass before a PR can be merged, configure a branch protection rule on `main`:

**Settings → Branches → Add rule → Require status checks to pass → add `build-and-scan`**

---

## Container security

- Runs as a non-root system user (`uid 10001 / gid 10001`).
- `allowPrivilegeEscalation: false` and all Linux capabilities dropped.
- Read-only root filesystem enforced via `readOnlyRootFilesystem: true`.
- `securityContext.runAsNonRoot: true` enforced at the Pod level.
- Fixed UID/GID ensures predictable security context behavior in Kubernetes.
- Image built from minimal base image to reduce attack surface.

---

## Observability

### Structured logging

All logs are written to stdout as JSON. Every log line includes:

| Field | Example | Notes |
|-------|---------|-------|
| `timestamp` | `2026-04-07T12:00:00.000000+00:00` | ISO-8601 UTC |
| `level` | `INFO` | |
| `logger` | `simple-time-service` | |
| `message` | `Request completed: ...` | |
| `trace_id` | `4bf92f3577b34da6...` | Present on every HTTP request |
| `span_id` | `00f067aa0ba902b7` | Present on every HTTP request |

`trace_id` and `span_id` are injected from the active OpenTelemetry span on every request. When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, the same span is also exported to Tempo, enabling a direct Loki → Tempo link from any log line.

### Distributed tracing

The platform uses a two-tier OpenTelemetry Collector topology:

```
Pod → OTel Agent (DaemonSet, node-local, :4318) → OTel Gateway (Deployment) → Tempo
```

The Helm chart injects the node IP at runtime via the downward API so the pod always reaches its local agent:

| Variable | Set by | Value |
|----------|--------|-------|
| `NODE_IP` | Downward API (`status.hostIP`) | Node's internal IP |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Helm template | `http://$(NODE_IP):4318` |
| `OTEL_SERVICE_NAME` | Helm values | `simple-time-service` |

All three are injected automatically when `tracing.enabled: true` in `charts/simple-time-service/values.yaml`. The `/health` and `/metrics` endpoints are excluded from tracing to avoid noise.

Locally, `trace_id` appears in logs without any collector. To also export spans, point the endpoint at a local OTel Collector or Tempo:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 docker compose up --build
```

---

## Prometheus metrics exposed

Metrics are emitted by [`prometheus-fastapi-instrumentator`](https://github.com/trallnag/prometheus-fastapi-instrumentator) and the standard Python `prometheus_client` collectors.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `http_requests_total` | Counter | `method`, `handler`, `status` | Total HTTP requests completed |
| `http_request_duration_seconds` | Histogram | `method`, `handler` | Request latency distribution (use for p50/p95/p99) |
| `http_request_duration_highr_seconds` | Histogram | — | High-resolution latency histogram (no label cardinality) |
| `http_request_size_bytes` | Histogram | `method`, `handler` | Incoming request body size |
| `http_response_size_bytes` | Histogram | `method`, `handler` | Outgoing response body size |
| `http_requests_inprogress` | Gauge | `method`, `handler` | Currently in-flight requests |
| `process_*` | Various | — | Python process metrics (CPU, memory, file descriptors) |
| `python_*` | Various | — | Python runtime metrics (GC, info) |
