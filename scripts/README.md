# Load Testing

Two scripts generate controlled HTTP traffic for validating Kubernetes HPA behavior and the Prometheus/Grafana observability pipeline.

| Script | Tool | Best for |
|--------|------|----------|
| `scripts/load_test.py` | Python stdlib | Quick, zero-dependency load generation |
| `scripts/k6-staged.js` | k6 | Staged ramping-arrival-rate scenarios with built-in thresholds |

Before running either script, forward the service port in one terminal:

```bash
kubectl port-forward svc/simple-time-service -n simple-time-service 8080:80
```

---

## Python load test (`load_test.py`)

No third-party libraries required - uses only Python's built-in `urllib` and `threading` modules.

| Requirement | Version |
|-------------|---------|
| Python | 3.8+ |

### Usage

```bash
# Default: 10 workers, 60 s, targeting http://localhost:8080/
python3 scripts/load_test.py

# Custom URL
python3 scripts/load_test.py --url http://localhost:8080/

# Higher concurrency and longer run
python3 scripts/load_test.py --url http://localhost:8080/ --concurrency 20 --duration 120

# Verbose per-request debug logging
python3 scripts/load_test.py --verbose
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | `http://localhost:8080/` | Target URL |
| `--concurrency` | `10` | Number of concurrent worker threads |
| `--duration` | `60` | Test duration in seconds |
| `--verbose` | off | Enable debug-level logging per request |

### Output

```
Load test completed
Total requests: 1234
Successful: 1230
Failed: 4
Average req/sec: 20.57
```

---

## k6 staged load test (`k6-staged.js`)

Requires [k6](https://k6.io/docs/get-started/installation/) v0.46+.

```bash
brew install k6   # macOS
k6 version        # verify
```

### Usage

```bash
# Default target: http://localhost:8080
k6 run scripts/k6-staged.js

# Custom target URL
BASE_URL=http://localhost:8080 k6 run scripts/k6-staged.js
```

### Traffic profile

Uses the `ramping-arrival-rate` executor. Each iteration sends two batched requests: `GET /` and `GET /health`. The Grafana dashboard filters out `/health`, so only `GET /` requests appear in traffic panels.

| Stage | Target rate | Duration |
|-------|-------------|----------|
| Warm-up | 50 req/s | 30 s |
| Ramp up | 50 → 100 req/s | 1 m |
| Peak | 100 → 200 req/s | 1 m |
| Ramp down | 200 → 0 req/s | 30 s |

Pre-allocated VUs: 100 (max: 300)

### Thresholds

k6 exits with a non-zero status code if either threshold is breached, making it suitable for CI gates.

| Metric | Threshold |
|--------|-----------|
| `http_req_failed` | < 10% error rate |
| `http_req_duration` | p(95) < 2000 ms |

---

## Observing autoscaling

After starting load generation, watch the HPA react in another terminal:

```bash
kubectl get hpa -n simple-time-service -w
```

> For a lightweight service like this, CPU utilization rises slowly under light traffic. Sustain load for a short period before the HPA triggers a scale-out event. Scale-down is intentionally conservative - the default stabilization window is 5 minutes (`hpa.scaleDown.stabilizationWindowSeconds`).
