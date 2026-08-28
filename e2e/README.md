# e2e — Unified Observability Platform

One Docker Compose project that runs **metrics, logs, alerting, tracing, and the
Thanos scaling layer** together, gated by Compose **profiles** so you can bring up
just the slice you need. Target host: **m7i-flex.large (2 vCPU / 8 GB)**.

## Quick start

```bash
cp .env.example .env          # then edit passwords + Slack webhook
make up-metrics               # or up-alerting / up-tracing / up-logging / up-scaling / up-all
make verify                   # smoke-test whatever is running
make down                     # stop
make nuke                     # stop + delete volumes
```

## Profiles and their RAM cost

RAM figures are the **sum of `mem_limit` caps** for that profile (actual idle use
is lower). `alerting` and `scaling` include the `metrics` services they build on.

| Profile   | Services                                                                 | ~RAM (caps) |
|-----------|--------------------------------------------------------------------------|-------------|
| `metrics` | prometheus, node-exporter, cadvisor, grafana                             | ~1.1 GB     |
| `alerting`| metrics + alertmanager, flaky-app                                        | ~1.3 GB     |
| `tracing` | jaeger, hotrod                                                           | ~0.5 GB     |
| `logging` | elasticsearch, logstash, kibana, filebeat, log-generator                | ~3.3 GB     |
| `scaling` | metrics + minio, minio-init, prometheus-us/eu/fed, thanos-* (5)          | ~3.8 GB     |
| `all`     | everything (23 containers)                                               | ~7.6 GB     |

`all` fits an 8 GB box but leaves little headroom — prefer subsets unless you
actually need the whole platform up at once.

## Port map (host ports — matches docker-compose.yml exactly)

| Service                     | Host port     | Notes                              |
|-----------------------------|---------------|------------------------------------|
| Grafana                     | 3000          | single Grafana for the platform    |
| Prometheus (central)        | 9090          |                                    |
| Prometheus federation master| 9091          | scaling profile                    |
| Alertmanager                | 9093          |                                    |
| node-exporter               | 9100          |                                    |
| cAdvisor                    | 8080          |                                    |
| HotROD                      | 8081          | moved off 8080                     |
| Kibana                      | 5601          |                                    |
| Elasticsearch               | 9200          |                                    |
| Jaeger UI                   | 16686         |                                    |
| Thanos Query                | 10902         |                                    |
| MinIO API / console         | 9000 / 9001   |                                    |
| Logstash beats input        | not published | container-network only (5044)      |

**Security-group ports to open** (only the UIs you actually browse to):
3000, 9090, 9091, 9093, 8080, 8081, 5601, 9200, 16686, 10902, 9000, 9001.
Leaf Prometheus (us/eu), Thanos gRPC (10901), and the Logstash beats input stay
internal — do not publish them.

## Secrets

All secrets live in `.env` (git-ignored), referenced from compose as `${VAR}`:
`GRAFANA_ADMIN_PASSWORD`, `MINIO_ROOT_PASSWORD`, `SLACK_WEBHOOK_URL`,
`ELASTIC_PASSWORD`. The Slack webhook is injected into Alertmanager's config at
container start via `sed` (Alertmanager can't expand env vars itself). MinIO
credentials are written into the Thanos `objstore.yml` at runtime by `minio-init`,
so they never sit in a tracked file.

## Notes

- `alerting` pulls in `metrics` (Prometheus/Grafana). The central Prometheus also
  scrapes `jaeger:14269`, so if you run without the `tracing` profile that one
  target shows down (and would trip `InstanceDown`). Run `all`, or add `tracing`,
  for a clean target list.
- On a dev box with other services already on 8080/8081, use a git-ignored
  `docker-compose.override.yml` to remap those ports — the committed file keeps
  the canonical port map above.
