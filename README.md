# SimpleTimeService

A minimal Python microservice that returns the current UTC timestamp and the caller's IP address as JSON.
The service is containerized with Docker, runs as a non-root user, and can be deployed to Kubernetes using a single manifest.

## Response format

```json
{
  "timestamp": "2026-04-07T12:00:00.000000+00:00",
  "ip": "203.0.113.42"
}
```

## Project structure

```
.
├── compose.yaml                   # Docker Compose for local development
├── k8s/
│   └── microservice.yaml          # Kubernetes Deployment + ClusterIP Service
└── sample-workload/
    ├── Dockerfile
    ├── requirements.txt
    ├── .dockerignore
    └── src/
        └── app.py
```

## Prerequisites

| Tool | Purpose |
|------|---------|
| Docker | Build and run the container |
| kubectl | Deploy to Kubernetes |
| A running Kubernetes cluster (Docker Desktop, Minikube, Kind, or EKS) | Deployment target |

---

## Quick Start

```bash
kubectl apply -f k8s/microservice.yaml
kubectl port-forward svc/simple-time-service 8080:80
curl http://localhost:8080/
```

## Running locally

### Docker Compose (recommended)

```bash
docker compose up --build
```

The service is available at `http://localhost:8080`.

### Docker only

```bash
docker build -t simple-time-service ./sample-workload
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

## Deploying to Kubernetes

The manifest at `k8s/microservice.yaml` contains both a `Deployment` and a `ClusterIP` `Service`. No namespace is specified in the manifest, so resources are deployed into whichever namespace your current kubectl context is set to (typically `default`). A single command is all that is needed:

```bash
kubectl apply -f k8s/microservice.yaml
```

> The provided manifest is designed to work without creating a separate namespace. If you choose to deploy into a custom namespace, create it first and pass `-n <namespace>`.

### Verify the deployment

```bash
# Wait for pods to become ready
kubectl rollout status deployment/simple-time-service

# Check pods
kubectl get pods -l app=simple-time-service -w

# Check the service
kubectl get svc simple-time-service
```

## Deployment validation

The application is considered successfully deployed when:

- Pods reach `Running` state
- Readiness probe passes
- `curl http://localhost:8080/` returns valid JSON

### Test the endpoint

Because the Service type is `ClusterIP`, use `kubectl port-forward` to reach it from your local machine:

```bash
kubectl port-forward svc/simple-time-service 8080:80
```

Then in a second terminal:

```bash
curl http://localhost:8080/
```

---

## Docker image

The public image is published on DockerHub:

```
docker.io/nabeemdev/simple-time-service:v1
```

Pull it directly:

```bash
docker pull nabeemdev/simple-time-service:v1
```

### Building and pushing your own image

If you fork this repo and want to use your own image:

```bash
# Build
docker build -t <your-dockerhub-username>/simple-time-service:v1 ./sample-workload

# Push
docker push <your-dockerhub-username>/simple-time-service:v1
```

Then update the `image:` field in `k8s/microservice.yaml` before applying:

```yaml
image: docker.io/<your-dockerhub-username>/simple-time-service:v1
```

## Cleanup

To remove deployed resources:

```bash
kubectl delete -f k8s/microservice.yaml
```

---

## Container security

- Runs as a non-root system user (`uid 10001 / gid 10001`).
- `allowPrivilegeEscalation: false` and all Linux capabilities dropped.
- Read-only root filesystem enforced via `readOnlyRootFilesystem: true`.
- `securityContext.runAsNonRoot: true` enforced at the Pod level.
- Fixed UID/GID ensures predictable security context behavior in Kubernetes.
- Image built from minimal base image to reduce attack surface.

## Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Returns `timestamp` and caller `ip` |
| `/health` | GET | Liveness / readiness probe (`{"status": "ok"}`) |

## Technology

- **Runtime**: Python 3.12 (slim base image)
- **Framework**: FastAPI + Uvicorn
- **Container**: multi-stage-free single-stage build kept small via `python:3.12-slim` and pip cache clearing
- **ASGI server**: Uvicorn (production-grade async Python server)