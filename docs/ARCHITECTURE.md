# Observability Platform — Architecture & Study Notes

This document explains the unified monitoring platform built across projects 5.1–5.4
and combined in `e2e/`. It is written to be **studied and explained**, not to look
impressive. If you can talk through the request-lifecycle walkthroughs and the
"why this and not that" section, you understand the system.

Target host throughout: a single **m7i-flex.large (2 vCPU / 8 GB)** Ubuntu 22.04
EC2 instance running Docker + Compose v2. Everything is containers on one box.

---

## 1. What the platform does

It answers the three questions of observability, plus alerting and scale:

- **Metrics** ("is it healthy, how much, how fast") — Prometheus scrapes numeric
  time series from the host, containers, and apps; Grafana visualises them.
- **Logs** ("what exactly happened") — Filebeat ships log lines, Logstash parses
  them, Elasticsearch stores/indexes them, Kibana searches them.
- **Traces** ("where did the time go across services") — apps emit spans over
  OTLP to Jaeger, which reconstructs end-to-end request timelines.
- **Alerting** — Prometheus rules fire, Alertmanager groups/routes them to Slack.
- **Scale** — Thanos turns many short-lived Prometheus instances into one global,
  durable, long-retention query surface backed by object storage.

---

## 2. End-to-end architecture (unified `e2e` stack)

```
                                   ┌────────────────────────────────────────────┐
                                   │                 GRAFANA :3000               │
                                   │   (one instance, provisioned datasources)   │
                                   └───┬───────────────┬───────────────┬─────────┘
                       Prometheus DS   │        Thanos │ DS    Elastic  │ DS
                                       ▼               ▼               ▼
        METRICS/ALERTING          ┌─────────┐   SCALING          LOGGING
   ┌──────────────┐  scrape  ┌────│Prometheus│───┐          ┌──────────────┐
   │ node-exporter│◀─────────│  (central)  :9090 │          │Elasticsearch │◀─┐
   │   :9100      │          │  rules: recording │          │   :9200      │  │
   ├──────────────┤          │         + alerting│          └──────▲───────┘  │
   │  cAdvisor    │◀─────────┤                    │                 │ bulk     │
   │   :8080      │          │ evaluates rules    │          ┌──────┴───────┐  │
   ├──────────────┤          │        │ alerts    │          │  Logstash    │  │
   │  flaky-app   │◀─────────┘        ▼           │          │ grok+date    │  │
   │   :8000      │           ┌───────────────┐   │          │  :5044(int)  │  │
   ├──────────────┤           │ Alertmanager  │   │          └──────▲───────┘  │
   │ jaeger :14269│◀──────┐   │    :9093      │   │                 │ beats    │
   └──────────────┘       │   │ group/inhibit │   │          ┌──────┴───────┐  │
                          │   └───────┬───────┘   │          │  Filebeat    │  │
   TRACING                │           ▼ webhook   │          └──────▲───────┘  │
   ┌──────────┐  OTLP     │        [ Slack ]      │                 │ tail     │
   │ HotROD   │──HTTP────▶│                       │          ┌──────┴───────┐  │
   │  :8081   │  :4318    │                       │          │ log-generator│  │
   └──────────┘           │                       │          │  /logs/app.log│  │
        ▲ traces          │                       │          └──────────────┘  │
        └──── Jaeger ──────┘                       │                            │
             all-in-one :16686                     │   Kibana :5601 ────────────┘
                                                    │
   SCALING (Thanos)                                 │
   ┌───────────────┐   ┌───────────────┐            │
   │ prometheus-us │   │ prometheus-eu │  leaves: min=max block=2h (no local compaction)
   │ ext:region=us │   │ ext:region=eu │            │
   └───┬───────────┘   └───┬───────────┘            │
       │ tsdb (ro)         │ tsdb (ro)              │
   ┌───▼──────┐        ┌───▼──────┐                 │
   │ sidecar  │        │ sidecar  │──upload 2h blocks──▶ ┌──────────┐
   │  -us     │        │  -eu     │                       │  MinIO   │  (S3 bucket "thanos")
   └───┬──────┘        └───┬──────┘                       │ :9000    │
       │ gRPC 10901        │ gRPC                         └────▲─────┘
       │                   │             ┌───────────┐        │ read
       └─────────┬─────────┴────────────▶│  Thanos   │◀───────┤
                 │      ┌───────────────▶│  Query    │   ┌────┴──────┐   ┌──────────────┐
                 │      │  gRPC          │  :10902   │   │ Thanos    │   │ Thanos       │
        ┌────────┴───┐  │                └───────────┘   │ Store     │   │ Compact      │
        │ prometheus │  │  (federation master :9091 = CONTRAST path, not Thanos)
        │  -fed      │──┘  scrapes /federate on both leaves
        └────────────┘

   (federation master duplicates a subset of leaf data; shown only to contrast
    with the Thanos object-storage path, which is how scale is actually solved.)
```

### 2.1 Metrics sub-project (5.1)

```
 kernel counters ──▶ node-exporter:9100 ─┐
 container cgroups ─▶ cAdvisor:8080 ──────┼─scrape 15s─▶ Prometheus:9090 ──▶ Grafana:3000
                                          │                   │ TSDB (15d)
                                          └──── app /metrics ──┘
```

### 2.2 Logging sub-project (5.2)

```
 app writes /logs/app.log ──▶ Filebeat (tail) ──beats:5044──▶ Logstash
     └─ "TS LEVEL service - msg"                                  │ grok → fields
                                                                  │ date → @timestamp
                                                                  ▼
                                              Elasticsearch app-logs-YYYY.MM.dd ──▶ Kibana:5601
```

### 2.3 Alerting + tracing sub-project (5.3)

```
 Prometheus ─eval rules─▶ ALERTS ─push─▶ Alertmanager ─group/inhibit/route─▶ Slack
 HotROD ─OTLP/HTTP :4318─▶ Jaeger all-in-one ─▶ Jaeger UI :16686
```

### 2.4 Scaling sub-project (5.4)

```
 leaves (region-labelled, local compaction OFF)
      │ sidecar uploads 2h blocks
      ▼
   MinIO (S3) ◀── Store Gateway (serves history) ◀── Compact (dedup/downsample, --wait)
      ▲
      └── Thanos Query fans out: sidecars (fresh) + store (history), dedup replica ──▶ Grafana
```

---

## 3. Request-lifecycle walkthroughs

These are the heart of the document. Each follows one unit of telemetry from
birth to a human, naming the **config file** and **specific setting** at every hop.

### 3.1 One CPU sample: kernel → Slack

1. **Kernel.** The Linux kernel maintains per-CPU counters in `/proc/stat` — a
   monotonically increasing count of "jiffies" spent in each mode (user, system,
   idle, iowait…).
2. **node-exporter** reads `/proc/stat` (it sees the host's procfs because compose
   runs it with `pid: host` and mounts `/:/host:ro`, flag `--path.rootfs=/host`).
   It exposes `node_cpu_seconds_total{cpu,mode}` as a counter on `:9100/metrics`.
   *Config:* `e2e/docker-compose.yml`, service `node-exporter`.
3. **Prometheus scrape.** Every 15s (`prometheus/prometheus.yml` → `global.scrape_interval`)
   Prometheus GETs `http://node-exporter:9100/metrics` because of the
   `scrape_configs` job `node-exporter`. The sample is stamped `instance="e2e-host"`
   (a `static_configs.labels` override).
4. **TSDB.** The scraped counter is appended to the local time-series database at
   `--storage.tsdb.path=/prometheus`, retained `--storage.tsdb.retention.time=15d`.
   A counter only ever goes up; rate is computed at query time, not stored.
5. **Recording rule.** Every 15s (`global.evaluation_interval`) Prometheus evaluates
   `prometheus/rules/recording.yml`. The rule
   `instance:node_cpu:busy_percent = 100 - (avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
   turns the raw idle counter into a busy-percent gauge and **stores it as a new
   series** so dashboards/alerts don't recompute the join every time.
6. **Alert rule.** `prometheus/rules/alerts.yml` has `InstanceDown` (`up == 0`,
   `for: 1m`). If node-exporter stops answering, its synthetic `up` series goes 0;
   after the `for:` pending period the alert flips PENDING → FIRING. (CPU-specific
   alerts would read the recording rule; the same mechanics apply.)
7. **Alertmanager handoff.** Prometheus pushes firing alerts to
   `alertmanager:9093` (`prometheus.yml` → `alerting.alertmanagers`).
8. **Grouping.** `alertmanager/alertmanager.yml` `route` groups by
   `["alertname","instance"]`, waits `group_wait: 30s` to collect siblings, then
   `group_interval: 5m` / `repeat_interval: 3h` govern re-sends.
9. **Inhibition.** If a `severity="critical"` alert is firing for the same
   `instance`, the `inhibit_rules` block suppresses `severity="warning"` alerts for
   that instance so you aren't double-paged.
10. **Slack.** The `slack-notifications` receiver POSTs to the webhook. The webhook
    itself is **not** in the file — compose `sed`-substitutes `${SLACK_WEBHOOK_URL}`
    (from `.env`) into a `/tmp` copy at container start, because Alertmanager can't
    expand env vars in its own config.

### 3.2 One log line: `print()` → Kibana panel

1. **App** writes a line to `/logs/app.log`:
   `2026-08-28T12:05:09.645952Z INFO catalog - rate limit hit`
   (`log-generator/generate.py`, shared Docker volume `logs`).
2. **Filebeat** tails that file — `filebeat/filebeat.yml`, a `filestream` input with
   `paths: [/logs/app.log]` — and ships each line to `logstash:5044`
   (`output.logstash.hosts`). Filebeat only forwards; it does not parse.
3. **Logstash beats input.** `logstash/pipeline/logstash.conf` `input { beats { port => 5044 } }`
   receives the raw event. Port 5044 is **container-network only** (never published).
4. **grok (must run first).** The `filter` block runs
   `grok { match => { "message" => "%{TIMESTAMP_ISO8601:log_timestamp} %{LOGLEVEL:log_level} %{WORD:service} - %{GREEDYDATA:log_message}" } }`
   producing fields `log_timestamp`, `log_level`, `service`, `log_message`.
5. **date (must run second).** `date { match => ["log_timestamp","ISO8601"] target => "@timestamp" }`
   overwrites the event's `@timestamp` with the **event time** parsed by grok. If
   date ran before grok, `log_timestamp` wouldn't exist yet and `@timestamp` would
   wrongly be the ingest time — **ordering matters**.
6. **Elasticsearch output.** `output { elasticsearch { index => "app-logs-%{+YYYY.MM.dd}" } }`
   bulk-indexes the doc into a daily index. ES dynamic mapping stores `log_level`
   as `text` **and** auto-creates `log_level.keyword` (a non-analysed sub-field).
7. **Aggregation needs `.keyword`.** "Count logs by level" is a terms aggregation,
   and terms aggs require an exact-match keyword field, not the analysed `text`
   field — so Kibana/Grafana aggregate on `log_level.keyword`.
8. **Kibana / Grafana.** Kibana (`:5601`) searches the `app-logs-*` pattern;
   Grafana's provisioned Elasticsearch datasource (`grafana/provisioning/datasources/datasources.yml`)
   drives the logs panel and the "volume by level" terms panel.

### 3.3 One trace: HotROD click → Jaeger UI

1. **Instrumented app.** HotROD handles `/dispatch?customer=…`; its OpenTelemetry
   SDK starts a root span on `frontend` and child spans as it calls the `customer`,
   `route`, and `driver` services (all inside one process for the demo).
2. **OTLP export.** HotROD is told `OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318`
   (`docker-compose.yml`), so it POSTs spans over **OTLP HTTP** to Jaeger's
   collector on `:4318` (`/v1/traces`).
3. **Jaeger ingest.** Jaeger all-in-one accepts OTLP because
   `COLLECTOR_OTLP_ENABLED=true`. Collector → in-memory store (all-in-one keeps
   traces in RAM; fine for a demo, not for production).
4. **Assembly.** Spans sharing a trace-id are stitched into one trace; the service
   graph (`frontend → customer → mysql`, `frontend → route`, …) is derived from
   span relationships.
5. **UI.** You browse `:16686`, pick service `frontend`, and see the waterfall.
6. **Jaeger's own health** is a *metrics* concern: Prometheus scrapes
   `jaeger:14269` (not 16686) so Jaeger's uptime shows up on the metrics side too.

---

## 4. Component reference

Ports are host ports from the unified stack. "Breaks if it dies" = observable impact.

| Component | Does | Talks to | Port | Config file | If it dies |
|---|---|---|---|---|---|
| Prometheus (central) | Scrape + store metrics, eval rules | node-exporter, cAdvisor, flaky-app, jaeger, alertmanager | 9090 | `prometheus/prometheus.yml`, `rules/*` | No new metrics/alerts; Grafana metric panels empty |
| node-exporter | Host metrics from /proc, /sys | (scraped by Prometheus) | 9100 | compose only | Lose host CPU/mem/disk; `InstanceDown` fires |
| cAdvisor | Per-container metrics | (scraped) | 8080 | compose only | Lose container dashboards |
| Grafana | Dashboards over all datasources | Prometheus, Thanos, Elasticsearch | 3000 | `grafana/provisioning/*`, `dashboards/*` | No UI; data still collected |
| Alertmanager | Group/route/inhibit alerts | Prometheus (in), Slack (out) | 9093 | `alertmanager/alertmanager.yml` | Alerts evaluated but not delivered |
| flaky-app | Demo app, ~20% 5xx counter | (scraped) | 8000 | `flaky-app/app.py` | `HighErrorRate` loses its source |
| Jaeger all-in-one | Collect + store + UI for traces | HotROD (OTLP in) | 16686 / 14269 | compose only | Traces dropped; UI gone |
| HotROD | Trace-generating demo app | Jaeger (OTLP) | 8081 | compose only | No new demo traces |
| Elasticsearch | Store + index logs | Logstash (in), Kibana/Grafana (out) | 9200 | compose env | Logging pipeline stalls; Logstash back-pressures |
| Logstash | Parse logs (grok/date) | Filebeat (in), ES (out) | 5044 (int) | `logstash/pipeline/logstash.conf` | Logs stop being parsed/indexed |
| Filebeat | Tail + ship log files | Logstash | — | `filebeat/filebeat.yml` | New log lines never leave the host |
| Kibana | Search/visualise logs | Elasticsearch | 5601 | compose env | Log UI gone; data intact |
| log-generator | Produce demo log lines | writes shared volume | — | `log-generator/generate.py` | No new demo logs |
| MinIO | S3 bucket for Thanos blocks | sidecars/store/compact | 9000/9001 | compose env | Thanos loses durable history |
| minio-init | Create bucket + gen objstore.yml | MinIO | — | compose inline | Thanos components can't start (bucket/config missing) |
| prometheus-us/eu | Regional leaves, compaction off | own node-exporter; sidecar reads TSDB | (internal) | `prometheus-us|eu/prometheus.yml` | That region's fresh data missing from Query |
| prometheus-fed | Federation master (contrast only) | leaves /federate | 9091 | `prometheus-fed/prometheus.yml` | Contrast demo only; no Thanos impact |
| Thanos sidecar | Upload blocks + serve fresh data | leaf TSDB, MinIO, Query | 10901 | uses `objstore.yml` | Region's blocks stop uploading; fresh data gone from Query |
| Thanos Store | Serve historical blocks from bucket | MinIO, Query | 10901 | `objstore.yml` | Historical queries return nothing |
| Thanos Compact | Compact + downsample bucket | MinIO | — | `objstore.yml` | Bucket grows; long-range queries slow (not immediately fatal) |
| Thanos Query | Global query fan-out + dedup | sidecars, store | 10902 | compose only | Grafana's Thanos datasource dark |

---

## 5. Why this tool and not the alternative

- **Prometheus (pull) vs push (StatsD/Graphite/InfluxDB push).** Pull means
  Prometheus owns the target list, so *target down* is directly observable
  (`up == 0`) — you can't tell a missing push from a healthy-but-silent service.
  Pull also centralises scrape interval and relabelling. Push is better only for
  short-lived batch jobs, which is exactly what the Pushgateway exists for.
- **ELK vs Loki.** ELK does full-text indexing — you can search arbitrary message
  content and run rich aggregations. Loki indexes only labels and greps the rest,
  so it's far cheaper but weaker at ad-hoc content search. For a capstone that
  demonstrates parsing/aggregation, ELK shows more; Loki would win on cost at scale.
- **Thanos vs Cortex/Mimir.** Thanos is *sidecar-based*: you keep running normal
  Prometheus and bolt object storage on. Cortex/Mimir ingest via remote-write into
  a separate clustered system. Thanos is the smaller step from an existing
  Prometheus estate; Mimir scales writes harder but is more infrastructure.
- **Thanos vs plain federation.** Federation (the `prometheus-fed` master) pulls a
  *subset* of series from each leaf and duplicates them upward — it doesn't scale
  past a handful of leaves and gives no long-term storage. Thanos keeps full
  fidelity, dedups replicas, and offloads history to cheap object storage. The
  federation master is in the stack **only to make this contrast concrete.**
- **Jaeger vs Zipkin.** Both do distributed tracing; Jaeger has first-class OTLP
  ingestion and a richer UI, and "all-in-one" is a single container for demos.
  Zipkin is simpler/older. Either works; Jaeger aligns better with OpenTelemetry.

---

## 6. Non-obvious design decisions

- **Pull vs push:** see §5 — the deciding factor is that pull makes absence
  detectable.
- **`for:` durations:** `InstanceDown for: 1m`, `HighErrorRate for: 2m`. The
  pending period filters transient blips (a single missed scrape, a momentary
  error spike) so you page on sustained conditions, not noise. Longer `for:` =
  fewer false pages but slower detection.
- **Why recording rules exist:** they precompute expensive/repeated expressions
  once per evaluation interval and store the result as a new series
  (`instance:node_cpu:busy_percent`, `job:flaky_app_requests:error_ratio`). Alerts
  and dashboards then read one cheap series instead of re-running a join/ratio on
  every query. Naming convention is `level:metric:operation`.
- **Why `external_labels` matter:** each leaf stamps `region` and `replica` on every
  series. Thanos uses `region` to keep leaves' data distinct and `replica` to
  deduplicate (`--query.replica-label=replica`). Without them, Thanos couldn't tell
  two Prometheus instances apart or collapse HA duplicates.
- **Why local compaction is disabled on the leaves:** leaves run
  `--storage.tsdb.min-block-duration=2h --storage.tsdb.max-block-duration=2h`. The
  sidecar uploads each raw 2h block to the bucket; **Thanos Compact** owns all
  compaction globally. If a leaf compacted locally it would rewrite blocks the
  sidecar already uploaded, producing **overlapping blocks** in the bucket, and
  Thanos Compact **halts** on overlap. One compactor per bucket, leaves compact
  never.
- **Why `log_level.keyword` for aggregation:** ES maps strings as analysed `text`
  (tokenised, good for search) plus a `.keyword` sub-field (exact, good for
  sort/aggregate). Terms aggregations require the exact field, so you aggregate on
  `log_level.keyword`, not `log_level`.
- **Why date-filter ordering matters:** grok must create `log_timestamp` before the
  date filter can parse it into `@timestamp`; reversed, `@timestamp` silently stays
  the ingest time and your dashboards drift from reality.
- **Secret handling:** Alertmanager can't expand env vars, so the webhook is
  `sed`-injected at startup; MinIO creds are written into `objstore.yml` at runtime
  by `minio-init`. Nothing sensitive is committed; `.env` is git-ignored.
- **One Grafana, provisioned from disk:** datasources and dashboards are YAML/JSON
  files, not click-ops, so the platform is reproducible and diff-able.

---

## 7. Failure modes & troubleshooting

| Symptom | Likely cause | Where to look / fix |
|---|---|---|
| Target shows `down` in Prometheus | Service not in the running profile, or wrong port | `/api/v1/targets`; bring up the owning profile; check job in `prometheus.yml` |
| `InstanceDown` firing for jaeger while you run metrics-only | Central Prometheus always scrapes `jaeger:14269` | Expected; run the `tracing` profile or `all` |
| Thanos Compact crash-loops with "overlapping blocks" | A leaf compacted locally | Ensure `min==max block-duration=2h` on every leaf; one compactor only |
| Thanos Store/Compact `mkdir … permission denied` | Named volume root-owned, image runs as nobody | Run those services as `user: "0:0"` (already set) or chown the volume |
| Store/sidecars missing from Query "Stores" page | `objstore.yml` creds wrong, or minio-init didn't finish | Check `minio-init` exited 0; check `/api/v1/stores`; verify bucket exists |
| ES won't start / exits 137 | Heap too big for `mem_limit` (cgroup OOM) | Lower `ES_JAVA_OPTS`; keep heap ≈ 50% of `mem_limit` |
| ES cluster health `yellow` | Single node can't allocate replica shards | Normal for one node; `green` needs ≥2 nodes |
| `app-logs-*` empty | grok failed (`_grokparsefailure` tag), or Logstash not up | Inspect a doc's `tags`; fix the grok pattern; confirm Filebeat→Logstash |
| Kibana stuck "server not ready" | Started before ES was ready | `depends_on: condition: service_healthy` (set); wait out `start_period` |
| No traces in Jaeger | HotROD got no traffic, or wrong OTLP endpoint | Hit `/dispatch?customer=123`; check `OTEL_EXPORTER_OTLP_ENDPOINT` |
| Alerts fire but no Slack | Empty/blank webhook, or sed didn't substitute | Set `SLACK_WEBHOOK_URL` in `.env`; check Alertmanager logs |
| Whole box gets slow / OOM-killer | Ran `all` on too little RAM | Run profile subsets; check `mem_limit` sums vs box size |

---

## 8. Scaling and cardinality limits

- **Cardinality is the #1 killer.** Every unique label-set is a separate time
  series held in Prometheus memory. A label with unbounded values (user id, full
  URL, request id) explodes series count and RAM. Keep labels low-cardinality;
  push high-cardinality detail to logs/traces, not metric labels.
- **Single Prometheus limits.** One Prometheus on this box comfortably handles
  thousands of targets' worth of *bounded* series, but it's a single point of
  failure and its local retention is finite. That's the wall.
- **What you do next:** run HA pairs (two Prometheis, `replica: A/B`), add Thanos
  sidecars, and let Thanos Query dedup and Thanos Store serve history from object
  storage — which is exactly the `scaling` profile. Beyond that, shard leaves by
  region/team, and downsample old data (Compact) so long-range dashboards stay fast.
- **Logs.** Single-node ES is fine for a demo; production wants a multi-node
  cluster (proper replicas → `green`), Index Lifecycle Management to roll/delete
  old daily indices, and enough disk headroom (indexing doubles storage briefly).
- **Traces.** All-in-one Jaeger stores traces in RAM and is demo-only. Production
  uses the Jaeger collector + a real backend (Elasticsearch/Cassandra) and
  tail-based sampling to keep volume sane.

---

## 9. Interview Q&A

1. **Pull vs push — why does Prometheus pull?** So Prometheus owns the target list
   and can detect a target being *down* (`up == 0`); a missing push is
   indistinguishable from a healthy silent service.
2. **What is a recording rule for?** Precompute an expensive/repeated expression on
   the evaluation interval and store it as a new series; alerts/dashboards read the
   cheap precomputed series.
3. **Naming convention for recording rules?** `level:metric:operation`, e.g.
   `instance:node_cpu:busy_percent`.
4. **What does `for:` do on an alert?** It's the pending period — the condition must
   stay true that long before FIRING, filtering transient blips.
5. **How does a counter become a rate?** Counters only increase; `rate()`/`irate()`
   compute per-second change over a window at query time. You never store the rate.
6. **Why `rate(...[5m])` and not `[1m]`?** A wider window smooths noise and tolerates
   missed scrapes; too wide and you lag real changes. 4–5× scrape interval is typical.
7. **How do alerts get to Slack?** Prometheus pushes firing alerts to Alertmanager;
   Alertmanager groups/inhibits/routes and a Slack receiver POSTs the webhook.
8. **What does `group_wait` vs `group_interval` vs `repeat_interval` mean?** Wait
   before sending a new group's first notification; min gap before adding new alerts
   to an existing group; how often to resend an unresolved group.
9. **What's an inhibition rule?** Suppress lower-severity alerts when a higher one is
   already firing for the same scope (here: critical suppresses warning per instance).
10. **Why external_labels on each Prometheus?** They identify the source
    (`region`) and replica so downstream systems (Thanos, federation) can
    distinguish and deduplicate series.
11. **What breaks if you leave local compaction on with Thanos?** Leaves rewrite
    already-uploaded blocks → overlapping blocks in the bucket → Thanos Compact halts.
12. **How many Thanos Compactors per bucket?** Exactly one. Multiple compactors on
    one bucket corrupt each other's work.
13. **What does the Thanos sidecar do?** Uploads the leaf's 2h blocks to object
    storage and serves the leaf's *fresh* (not-yet-uploaded) data to Query over gRPC.
14. **What does Thanos Store do?** Makes the *historical* blocks in the bucket
    queryable over the same gRPC Store API.
15. **How does Thanos Query dedup HA replicas?** `--query.replica-label=replica`
    collapses series that are identical except for the `replica` label.
16. **Federation vs Thanos — when federation?** Federation is fine for pulling a
    small curated subset up one level; it doesn't scale to many leaves and has no
    durable long-term storage. Thanos is the real scale/retention answer.
17. **Why ELK over Loki?** Full-text indexing and rich aggregations vs Loki's
    label-only indexing; ELK is heavier but far more searchable.
18. **Grok before date — why the order?** Grok extracts `log_timestamp`; the date
    filter needs that field to set `@timestamp`. Reversed, `@timestamp` stays ingest
    time.
19. **Why `log_level.keyword`?** Terms aggregations need the exact (`keyword`)
    sub-field, not the analysed `text` field.
20. **Filebeat vs Logstash — why both?** Filebeat is a light shipper (tail + send);
    Logstash does the heavy parsing/enrichment. Separating them keeps the edge cheap.
21. **Why is Beats input not published?** Only Filebeat (same Docker network) needs
    it; exposing 5044 to the host/internet is needless attack surface.
22. **Why single-node ES shows yellow, not green?** Replica shards can't be placed on
    the only node; green needs another node to hold replicas.
23. **How does a trace get from app to Jaeger here?** OpenTelemetry SDK emits spans
    over OTLP HTTP to `jaeger:4318`; Jaeger (with `COLLECTOR_OTLP_ENABLED=true`)
    ingests and assembles them by trace-id.
24. **Why is Jaeger scraped on 14269, not 16686?** 16686 is the UI; 14269 is Jaeger's
    own Prometheus metrics endpoint.
25. **How are secrets kept out of git?** All in `.env` (git-ignored); the Slack
    webhook is `sed`-injected into Alertmanager config at startup, and MinIO creds
    are written into `objstore.yml` at runtime by `minio-init`.
26. **What's the biggest scaling risk in this design?** Metric cardinality —
    unbounded label values blow up series count and Prometheus RAM.
27. **How would you make Prometheus itself HA?** Run two identical Prometheis
    (`replica: A/B`) and let Thanos Query dedup; store history in object storage.
28. **Why cap JVM heaps and set mem_limit?** So one runaway JVM can't consume all
    host RAM and trigger the OOM-killer against everything else on the box.

---

## 10. Two-minute "walk me through your project" script

> "I built a single-box observability platform in Docker Compose that covers the
> three pillars — metrics, logs, and traces — plus alerting and a scaling layer,
> all wired into one Grafana.
>
> For **metrics**, Prometheus scrapes a node-exporter for host stats, cAdvisor for
> containers, and a demo app. I use recording rules to precompute things like CPU
> busy-percent and the app's error ratio, and alert rules — InstanceDown and
> HighErrorRate — that push to Alertmanager, which groups and inhibits alerts and
> sends them to Slack.
>
> For **logs**, a generator writes to a file, Filebeat tails it, Logstash parses each
> line with grok and fixes the timestamp with a date filter, and Elasticsearch
> indexes it into daily indices that Kibana and Grafana can search.
>
> For **traces**, the HotROD demo emits OpenTelemetry spans over OTLP to Jaeger, so I
> can see an end-to-end request waterfall.
>
> The interesting part is **scaling with Thanos**. I run two region-labelled
> Prometheus leaves with local compaction disabled — that's critical, because if a
> leaf compacts locally it creates overlapping blocks in object storage and Thanos
> Compact halts. Sidecars upload 2-hour blocks to MinIO; Thanos Store serves history
> from the bucket; Thanos Query fans out across both sidecars and the store and
> deduplicates HA replicas; and Grafana points at Thanos Query instead of a single
> Prometheus. I also included a federation master purely to contrast the old scaling
> approach with the Thanos one.
>
> Everything is profile-gated so I can bring up just metrics, or the whole platform;
> secrets live in a git-ignored `.env`; every heavy service has a memory limit and a
> healthcheck with proper dependency ordering; and a `verify.sh` script smoke-tests
> the whole thing — targets up, rules loaded, ES green/yellow, logs indexed, Thanos
> stores healthy, and a trace present."
