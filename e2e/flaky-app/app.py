# Project 5.3 — flaky demo app.
# Exposes Prometheus metrics on :8000/metrics and increments a labelled request
# counter with roughly a 20% 5xx rate, so the HighErrorRate alert has real data
# to fire on. Kept deliberately tiny — no web framework, just the client lib.

import random
import time

from prometheus_client import Counter, start_http_server

# code label lets the recording rule compute a 5xx ratio with code=~"5..".
REQUESTS = Counter(
    "app_requests_total",
    "Total HTTP requests handled by the flaky demo app.",
    ["method", "endpoint", "code"],
)

ERROR_RATE = 0.20  # ~20% of requests fail — comfortably above the 10% alert threshold


def handle_one():
    code = "500" if random.random() < ERROR_RATE else "200"
    REQUESTS.labels(method="GET", endpoint="/api/orders", code=code).inc()


if __name__ == "__main__":
    start_http_server(8000)
    print("flaky-app: metrics on :8000/metrics, ~20% 5xx", flush=True)
    while True:
        handle_one()
        time.sleep(0.2)   # ~5 req/s keeps rate() over 5m meaningful
