"""
Simple HTTP load generator for validating Kubernetes autoscaling behavior and
Prometheus/Grafana observability pipelines.

Usage:
    python3 scripts/load_test.py
    python3 scripts/load_test.py --url http://localhost:8080/
    python3 scripts/load_test.py --url http://localhost:8080/ --concurrency 20 --duration 120
    python3 scripts/load_test.py --verbose
"""

import argparse
import logging
import threading
import time
import urllib.error
import urllib.request
from typing import Dict


logger = logging.getLogger("load-test")


def setup_logging(verbose: bool) -> None:
    """
    Configure application logging.
    """

    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s - %(message)s",
    )


def worker(
    url: str,
    stop_at: float,
    stats: Dict[str, int],
    lock: threading.Lock,
    worker_id: int,
) -> None:
    """
    Send repeated HTTP requests until the test duration expires.
    """
    logger.debug("Worker %s started", worker_id)

    while time.time() < stop_at:
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                response.read()
                code = response.getcode()

                with lock:
                    stats["total"] += 1
                    if 200 <= code < 400:
                        stats["success"] += 1
                    else:
                        stats["failed"] += 1

                logger.debug(
                    "Worker %s received response code %s", worker_id, code)

        except urllib.error.HTTPError as exc:
            with lock:
                stats["total"] += 1
                stats["failed"] += 1
            logger.debug("Worker %s HTTP error: %s", worker_id, exc.code)

        except urllib.error.URLError as exc:
            with lock:
                stats["total"] += 1
                stats["failed"] += 1
            logger.debug("Worker %s URL error: %s", worker_id, exc)

        except Exception as exc:
            with lock:
                stats["total"] += 1
                stats["failed"] += 1
            logger.debug("Worker %s unexpected error: %s", worker_id, exc)

    logger.debug("Worker %s finished", worker_id)


def main() -> None:
    """
    Parse arguments and run the load test.
    """

    parser = argparse.ArgumentParser(
        description="Generate controlled HTTP traffic to validate Kubernetes HPA behavior and Prometheus/Grafana monitoring."
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8080/",
        help="Target URL (default: http://localhost:8080/)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=10,
        help="Number of concurrent workers (default: 10)",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=60,
        help="Duration in seconds (default: 60)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug logging",
    )

    args = parser.parse_args()
    setup_logging(args.verbose)

    stats = {"total": 0, "success": 0, "failed": 0}
    lock = threading.Lock()
    threads = []
    stop_at = time.time() + args.duration

    logger.info("Starting load test")
    logger.info("URL: %s", args.url)
    logger.info("Concurrency: %s", args.concurrency)
    logger.info("Duration: %ss", args.duration)

    for idx in range(args.concurrency):
        thread = threading.Thread(
            target=worker,
            args=(args.url, stop_at, stats, lock, idx + 1),
            daemon=True,
        )
        thread.start()
        threads.append(thread)

    for thread in threads:
        thread.join()

    rps = stats["total"] / args.duration if args.duration > 0 else 0

    logger.info("Load test completed")
    logger.info("Total requests: %s", stats["total"])
    logger.info("Successful: %s", stats["success"])
    logger.info("Failed: %s", stats["failed"])
    logger.info("Average req/sec: %.2f", rps)


if __name__ == "__main__":
    main()
