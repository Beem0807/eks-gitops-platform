import http from "k6/http";
import { check } from "k6";

/**
 * Staged HTTP load generator for validating Kubernetes autoscaling
 * behavior and Prometheus/Grafana observability pipelines.
 *
 * This version uses a ramping arrival rate so request volume is controlled
 * more explicitly than a VU/sleep-based script.
 *
 * Usage:
 *   k6 run scripts/k6-staged.js
 *   BASE_URL=http://localhost:8080 k6 run scripts/k6-staged.js
 *
 * Environment variables:
 *   BASE_URL  Base service URL (default: http://localhost:8080)
 */

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export const options = {
  scenarios: {
    staged_traffic: {
      executor: "ramping-arrival-rate",
      startRate: 50,
      timeUnit: "1s",
      preAllocatedVUs: 100,
      maxVUs: 300,
      stages: [
        { target: 50, duration: "30s" },
        { target: 100, duration: "1m" },
        { target: 200, duration: "1m" },
        { target: 0, duration: "30s" },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.10"],
    http_req_duration: ["p(95)<2000"],
  },
};

export function setup() {
  console.log("Starting staged load test");
  console.log(`Base URL: ${BASE_URL}`);
  console.log("Executor: ramping-arrival-rate");
  console.log("Each iteration sends 2 requests: / and /health");
}

export default function () {
  const responses = http.batch([
    ["GET", `${BASE_URL}/`],
    ["GET", `${BASE_URL}/health`],
  ]);

  check(responses[0], {
    "root status is 200": (r) => r.status === 200,
  });

  check(responses[1], {
    "health status is 200": (r) => r.status === 200,
  });
}

export function teardown() {
  console.log("Load test completed");
}