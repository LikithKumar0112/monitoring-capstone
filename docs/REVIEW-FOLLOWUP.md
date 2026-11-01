# Review Follow-up: Advanced Monitoring, Logging, Alerting & Distributed Tracing

This document responds to the Skillfyme assignment review. It lists what changed on the
`fix/review-followup` branch, what evidence supports each change, and which review suggestions are
still open.

All runs were on one EC2 host with Docker 29. The screenshots and test output are from 31 October 2026.

**Status labels**

| Label | Meaning |
|---|---|
| **Demonstrated** | Implemented, and the evidence below shows it working |
| **Tested** | Implemented and checked by command, but no screenshot shows the result |
| **Configured** | Present in the config, but its effect has not been shown |
| **Open** | Not implemented |

## Summary

| Review section | Item | Status |
|---|---|---|
| 1. Prometheus and Grafana | cAdvisor runs without `privileged` (5.1) | **Demonstrated** |
| 1. Prometheus and Grafana | Application metrics, alert thresholds and SLIs in the 5.1 dashboard | **Open** |
| 2. ELK | Elasticsearch authentication on the 5.2 stack, as an optional overlay | **Demonstrated** |
| 2. ELK | Log pipeline still works with authentication on | **Demonstrated** |
| 2. ELK | Authenticated communication between Elastic components | **Tested** (Logstash to Elasticsearch, Kibana to Elasticsearch, without TLS) |
| 2. ELK | Extra log metadata (environment, application name, request ID) | **Open** |
| 3. Alerting | Inhibition rule shown with a controlled test | **Tested** (see the note in section 3) |
| 4. Tracing | Custom span or tag in Jaeger | **Open** |
| 5. Thanos | Cross-region query through Thanos and Grafana | **Demonstrated** |
| 5. Thanos | Federation running as a comparison path | **Demonstrated** |
| 5. Thanos | Practical limitations of federation shown | **Open** |
| 5. Thanos | Block upload to MinIO | **Configured** (bucket was empty when captured) |
| 5. Thanos | Historical queries after retention expires, and downsampling | **Open** |
| 6. Unified platform | `all` profile memory headroom | **Open** |
| 7. Secrets | No hardcoded MinIO credentials in standalone 5.4 | **Demonstrated** |
| 7. Secrets | `objstore.yml` generated at runtime from `.env` | **Tested** |
| 7. Secrets | TLS and production secret management | **Open** |
| 8. Documentation | Implementation checklist | **Demonstrated** (this document) |

## 1. Prometheus and Grafana (5.1)

**Review point:** cAdvisor used `privileged: true`.

**Change:** `privileged: true` is removed. cAdvisor keeps the `/dev/kmsg` device and read-only host mounts.

The cAdvisor image also changed from `v0.49.1` to `ghcr.io/google/cadvisor:0.56.2`. The old version
could not talk to Docker 29, which rejected its API version. `v0.52.1` connected but could not read
Docker 29's containerd image store. Version `0.56.2` works.

**cAdvisor service definition, with no `privileged` setting:**

![cAdvisor without privileged](screenshots/cadviosor%20privilage.png)

**Prometheus targets: cadvisor, node-exporter and prometheus all UP:**

![5.1 Prometheus targets](screenshots/5.1%20prom%20targets.png)

**Container metrics with names, from the unprivileged cAdvisor.** The query is
`rate(container_cpu_usage_seconds_total{name!=""}[1m])`, and the results include `grafana`,
`prometheus`, `node-exporter` and `cadvisor`:

![cAdvisor metrics](screenshots/prom%20graph.png)

**Still open:** application metrics, explicit alert thresholds and SLIs in the 5.1 dashboard.

## 2. Centralized Logging (5.2)

**Review point:** Elasticsearch security was disabled, and production authentication was not included.

**Change:** security is controlled by `ES_SECURITY_ENABLED`, and the overlay
`project-5.2-ELK-stack/docker-compose.security.yml` adds the authenticated setup:

- A one-time `es-setup` service sets the `kibana_system` password, so Kibana can connect to Elasticsearch.
- Logstash writes to Elasticsearch as `elastic`, using the password from `.env`.
- Logstash's built-in monitoring is turned off, because it polled Elasticsearch without credentials
  and logged repeated 401 warnings.
- The overlay refuses to start if `ELASTIC_PASSWORD` or `KIBANA_PASSWORD` is missing.

**Kibana now requires a login:**

![Kibana login](screenshots/kibana%20login.png)

**Elasticsearch rejects a request with no credentials (`security_exception`):**

![Security exception](screenshots/security%20exceprtion.png)

**Opening `:9200` in a browser triggers an HTTP Basic Auth prompt:**

![Elasticsearch login prompt](screenshots/elastic%20popup%20login.png)

**After logging in, parsed logs are still arriving.** Discover shows 991 documents in 15 minutes, with
the `log_level`, `log_message` and `service` fields:

![Kibana Discover](screenshots/log%20level%20and%20service.png)

**Limitations**

- Security is off by default. It applies only when `ES_SECURITY_ENABLED=true` and the overlay are both used.
- Traffic is plain HTTP, so credentials are not encrypted in transit. Production would also need TLS.
- The security-off configuration was not re-run after the Logstash output gained credentials.
- The unified `e2e` stack still has `xpack.security.enabled=false`.

**Still open:** extra log metadata (environment, application name, request ID).

## 3. Alerting (5.3)

**Review point:** the inhibition rule was configured but not demonstrated.

**Rule fix:** the test exposed a defect. The error-ratio recording rule aggregated `by (job)`, which
removed the `instance` label from `HighErrorRate`. The inhibit rule uses `equal: ["instance"]`, so a
critical alert for a specific instance could never suppress it. The rule now aggregates
`by (job, instance)`.

**Test:** `project-5.3-Alerts-Tracing/scripts/inhibition-test.sh`

1. Confirms the real `HighErrorRate` warning from Prometheus has reached Alertmanager.
2. Injects a synthetic critical alert for the same instance, `flaky-app:8000`.
3. Injects a synthetic control warning for a different instance, `other-host:9999`.
4. Reads each alert's state from the Alertmanager API and reports PASS or FAIL.

**Result, copied from the terminal:**

```
BEFORE the test:
STATE       ALERTNAME                SEVERITY  INSTANCE         INHIBITED BY
active      HighErrorRate            warning   flaky-app:8000   -

AFTER the test:
STATE       ALERTNAME                SEVERITY  INSTANCE         INHIBITED BY
active      InhibitionTestControl    warning   other-host:9999  -
active      InhibitionTestCritical   critical  flaky-app:8000   -
suppressed  HighErrorRate            warning   flaky-app:8000   b2ed4d9c314e

PASS: HighErrorRate (warning, flaky-app:8000) is SUPPRESSED by the critical alert on the same instance;
      the control warning on other-host:9999 is still ACTIVE.
```

**Alertmanager during the test, in its default view.** The critical alert and the control warning are
listed, and `HighErrorRate` is absent:

![Alertmanager during the test](screenshots/alert%20manager.png)

**Note on this evidence:** the **Inhibited** box is not ticked in this screenshot, so it shows
`HighErrorRate` missing from the list, not marked as inhibited. The suppressed state itself comes from
the terminal output above. The critical alert is injected for the test, while the suppressed warning
is a real Prometheus alert.

The Slack webhook was empty during this run, so no Slack delivery was tested for this scenario. To
support that, Alertmanager in 5.3 now starts with a warning when the webhook is empty. Previously it
crashed on startup.

## 4. Distributed Tracing

**Status: Open.** No custom span or tag has been added. The stack still uses the standard HotROD
example, as covered in the first submission.

## 5. Thanos Scaling (5.4)

**Image change:** the pinned `minio/minio` and `minio/mc` images can no longer be pulled from Docker
Hub or quay.io, so 5.4 could not start as committed. It now uses `bitnamilegacy/minio:2024.9.13` and
`bitnamilegacy/minio-client:2024.9.16`, the closest available versions.

**Thanos Query sees both sidecars and the Store, all UP, with region labels:**

![Thanos stores](screenshots/thanos%20stores.png)

The Min Time and Max Time columns are empty because the stack had just been restarted when this was captured.

**A global `up` query returns series from both regions:**

![Thanos up query](screenshots/thanos%20up.png)

Deduplication is unticked here. Ticking it would not reduce the four series, because each region has
one replica and `region` keeps the series distinct. The `replica` label and
`--query.replica-label=replica` are configured, but deduplication has not been demonstrated, since that
needs two replicas of the same region.

**Grafana querying through the Thanos data source, with data from `eu-west` and `us-east`:**

![Grafana through Thanos](screenshots/grafana%20queries.png)

Both regions are simulated on a single EC2 host, so they report the same machine's metrics through
separate Prometheus instances.

**Federation path: `prometheus-fed` scrapes `/federate` on both leaf Prometheus servers:**

![Federation targets](screenshots/prometheus%20targets.png)

This shows that federation runs as a comparison path. It does not show federation's limitations, which
the review suggested demonstrating.

**MinIO `thanos` bucket:**

![MinIO bucket](screenshots/minio%20bucket.png)

**Note on this evidence:** the bucket exists and is private, but it reports 0.0 B, and a later check of
the MinIO volume confirmed it held no objects. The stack ran for less than the 2 hours needed to produce
the first block, so uploads have not been demonstrated.

**Still open:** block upload evidence, historical queries after local retention expires, and Thanos
Compact downsampling.

## 6. Unified Platform (`e2e`)

**Changes:** the same MinIO and cAdvisor image updates as above, and `privileged: true` removed from cAdvisor.

**Not re-run.** The `e2e` compose file passed `docker compose config`, but the stack and `verify.sh`
were not run after these changes, and its images were not started together.

**Known gaps in `e2e`:**

- The recording rule still aggregates `by (job)`, so the section 3 defect remains here.
- It does not have the empty-webhook handling added to 5.3.
- MinIO and Grafana still have fallback defaults (`minioadmin`, `admin`).
- The `all` profile headroom on an 8 GB host, raised in section 6 of the review, has not been changed.

## 7. Security and Secrets

**Review point:** standalone 5.4 hardcoded `minioadmin` credentials, unlike the `.env` approach used elsewhere.

**Changes**

- `docker-compose.yml` in 5.4 now requires `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` from `.env`, with no fallback.
- `thanos/objstore.yml` is removed. A one-time `minio-init` service generates it at runtime from the
  same variables, into a shared Docker volume. `objstore.yml.example` documents its format.
- `git grep minioadmin -- project-5.4-scaling-monitoring` returns nothing.

**Without `.env`, Compose refuses to start 5.4:**

![No hardcoded credentials](screenshots/no%20hardcoded%20creds.png)

**Remaining development settings**

- `insecure: true` remains in `objstore.yml`, because MinIO uses plain HTTP on the Docker network.
- Grafana in 5.4 still falls back to `admin` if `GRAFANA_ADMIN_PASSWORD` is unset.
- TLS and a dedicated secrets manager are not implemented.

## 8. Documentation

The Summary table above is the implementation checklist the review suggested.

`docs/BUILD-GUIDE.md` still shows the old cAdvisor and MinIO images and `privileged: true`. The compose
files and this document are the current reference.

## Reproducing the Results

Every command runs from the repository root, using a `.env` copied from `.env.example` with real values.
The stacks share container names and ports, so stop one with `docker compose down` before starting
another. 5.2 can run alongside 5.3.

```bash
# 5.1 Prometheus and Grafana
cd project-5.1-prometheus-grafana
docker compose --env-file ../.env up -d

# 5.2 ELK with security on
cd project-5.2-ELK-stack
ES_SECURITY_ENABLED=true docker compose --env-file ../.env \
  -f docker-compose.yml -f docker-compose.security.yml up -d --build

# 5.3 Alerting and the inhibition test (wait about 3 minutes for HighErrorRate before the script)
cd project-5.3-Alerts-Tracing
docker compose --env-file ../.env up -d --build
./scripts/inhibition-test.sh

# 5.4 Thanos
cd project-5.4-scaling-monitoring
docker compose --env-file ../.env up -d
```
