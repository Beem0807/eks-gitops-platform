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

---

## Running locally

### Docker Compose (recommended)

```bash
docker compose up --build
```

The service is available at `http://localhost:8080`.

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

| Tag | Metrics endpoint | Use when |
|-----|-----------------|----------|
| `v1` | No | You don't need Prometheus metrics |
| `latest` | Yes (`/metrics`) | You want Prometheus scraping via ServiceMonitor |

> **`v1`** is a pinned baseline - the original service with no instrumentation.
> **`latest`** tracks `main` and includes the Prometheus `/metrics` endpoint exposed by `prometheus-fastapi-instrumentator`. Use this tag when deploying with the Helm chart and `serviceMonitor.enabled=true`.

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
